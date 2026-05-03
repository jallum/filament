defmodule Filament.Event do
  @moduledoc false

  @supported_types [:string, :integer, :float, :boolean, :atom]

  defmacro defevent(name, do: block) do
    caller_module = __CALLER__.module
    event_name = extract_event_name(name)
    event_module = Module.concat(caller_module, event_name)

    fields = extract_fields(block)
    Enum.each(fields, &validate_field!(&1, __CALLER__))

    enforce_keys = build_enforce_keys(fields)
    struct_fields = build_struct_fields(fields)
    type_fields = build_type_fields(fields)
    escaped_fields = Macro.escape(fields)

    build_event_module_ast(event_module, enforce_keys, struct_fields, type_fields, escaped_fields)
  end

  defp extract_event_name({:__aliases__, _, segments}), do: List.last(segments)
  defp extract_event_name(other), do: other

  defp build_enforce_keys(fields) do
    fields |> Enum.filter(& &1.required) |> Enum.map(& &1.name)
  end

  defp build_struct_fields(fields) do
    Enum.map(fields, fn
      %{name: n, default: d} when d != :__no_default__ -> {n, d}
      %{name: n} -> {n, nil}
    end)
  end

  defp build_type_fields(fields) do
    Enum.map(fields, fn %{name: n, type: t} -> {n, elixir_type_ast(t)} end)
  end

  defp build_event_module_ast(event_module, enforce_keys, struct_fields, type_fields, escaped_fields) do
    inner = build_event_inner_ast(enforce_keys, struct_fields, type_fields, escaped_fields)

    quote do
      defmodule unquote(event_module) do
        unquote(inner)
      end
    end
  end

  defp build_event_inner_ast(enforce_keys, struct_fields, type_fields, escaped_fields) do
    quote do
      @enforce_keys unquote(enforce_keys)
      defstruct unquote(struct_fields)

      @type t :: %__MODULE__{unquote_splicing(type_fields)}

      @doc "Encode this event to a JSON binary."
      @spec encode(t()) :: {:ok, binary()} | {:error, term()}
      def encode(%__MODULE__{} = event) do
        Jason.encode(Map.from_struct(event))
      end

      @doc "Decode a JSON binary or string-keyed map into this event struct."
      @spec decode(binary() | map()) :: {:ok, t()} | {:error, term()}
      def decode(data) when is_binary(data) do
        case Jason.decode(data) do
          {:ok, map} -> decode(map)
          {:error, _} = err -> err
        end
      end

      def decode(map) when is_map(map) do
        do_decode(map, unquote(escaped_fields), unquote(enforce_keys))
      end

      defp do_decode(map, fields, enforce) do
        Filament.Event.decode_fields(map, fields, enforce, __MODULE__)
      end

      unquote(cast_field_clauses_ast())
    end
  end

  defp cast_field_clauses_ast do
    quote do
      defp cast_field(v, :string) when is_binary(v), do: {:ok, v}
      defp cast_field(v, :integer) when is_integer(v), do: {:ok, v}
      defp cast_field(v, :float) when is_float(v), do: {:ok, v}
      defp cast_field(v, :float) when is_integer(v), do: {:ok, v * 1.0}
      defp cast_field(v, :boolean) when is_boolean(v), do: {:ok, v}
      defp cast_field(v, :atom) when is_binary(v), do: {:ok, String.to_existing_atom(v)}
      defp cast_field(v, :atom) when is_atom(v), do: {:ok, v}
      defp cast_field(v, type), do: {:error, {:type_mismatch, expected: type, got: v}}
    end
  end

  @doc false
  def decode_fields(map, fields, enforce, module) do
    result = reduce_fields(map, fields)
    finalize_decode(result, enforce, module)
  end

  defp reduce_fields(map, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      key_str = Atom.to_string(field.name)

      case Map.fetch(map, key_str) do
        {:ok, value} -> cast_and_accumulate(value, field, acc)
        :error when field.required -> {:halt, {:error, {:missing_field, field.name}}}
        :error -> {:cont, {:ok, Map.put(acc, field.name, field_default(field))}}
      end
    end)
  end

  defp cast_and_accumulate(value, field, acc) do
    case cast_value(value, field.type) do
      {:ok, cast} -> {:cont, {:ok, Map.put(acc, field.name, cast)}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp field_default(%{default: :__no_default__}), do: nil
  defp field_default(%{default: d}), do: d

  defp finalize_decode({:ok, attrs}, enforce, module) do
    {:ok, struct!(module, attrs)}
  rescue
    ArgumentError -> {:error, {:missing_keys, enforce}}
  end

  defp finalize_decode({:error, _} = err, _enforce, _module), do: err

  defp cast_value(v, :string) when is_binary(v), do: {:ok, v}
  defp cast_value(v, :integer) when is_integer(v), do: {:ok, v}
  defp cast_value(v, :float) when is_float(v), do: {:ok, v}
  defp cast_value(v, :float) when is_integer(v), do: {:ok, v * 1.0}
  defp cast_value(v, :boolean) when is_boolean(v), do: {:ok, v}
  defp cast_value(v, :atom) when is_binary(v), do: {:ok, String.to_existing_atom(v)}
  defp cast_value(v, :atom) when is_atom(v), do: {:ok, v}
  defp cast_value(v, type), do: {:error, {:type_mismatch, expected: type, got: v}}

  # ── Compile-time helpers (not emitted into generated module) ──────────────

  defp extract_fields({:__block__, _, stmts}), do: Enum.map(stmts, &parse_field/1)
  defp extract_fields(single_stmt), do: [parse_field(single_stmt)]

  defp parse_field({:field, _meta, [name, type | rest]}) do
    opts = List.flatten(rest)

    %{
      name: name,
      type: type,
      required: Keyword.get(opts, :required, false),
      default: Keyword.get(opts, :default, :__no_default__)
    }
  end

  defp validate_field!(%{name: name, type: type, required: req, default: def_}, caller) do
    if type not in @supported_types do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "defevent field #{inspect(name)}: unsupported type #{inspect(type)}. " <>
            "Supported: #{inspect(@supported_types)}"
    end

    if req and def_ != :__no_default__ do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "defevent field #{inspect(name)}: :required and :default are mutually exclusive"
    end
  end

  defp elixir_type_ast(:string), do: quote(do: String.t())
  defp elixir_type_ast(:integer), do: quote(do: integer())
  defp elixir_type_ast(:float), do: quote(do: float())
  defp elixir_type_ast(:boolean), do: quote(do: boolean())
  defp elixir_type_ast(:atom), do: quote(do: atom())
end
