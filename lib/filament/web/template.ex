defmodule Filament.Web.Template do
  @moduledoc false

  alias Filament.Template
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Comprehension
  alias Phoenix.LiveView.Rendered

  def to_rendered(%Template{} = template) do
    # Encoded once, so `Filament.Web.track/2` compares finished values.
    dynamic = template |> prepare() |> Enum.map(&encode/1)

    %Rendered{
      static: template.static,
      fingerprint: template.fingerprint,
      dynamic: fn _track -> dynamic end,
      root: Filament.Web.root?(template.vnode),
      caller: :not_available
    }
  end

  defp prepare(template), do: Enum.zip_with(template.bindings, template.values, &prepare_binding/2)

  defp prepare_binding({:components, key}, value), do: {key, components(value), :opaque}
  defp prepare_binding({{:rows, keyed?}, key}, value), do: {key, rows(value, keyed?), :opaque}

  defp prepare_binding({kind, key}, value) do
    cond do
      kind == :child and (is_struct(value, Template) or is_struct(value, Rendered)) ->
        {key, Filament.Web.to_rendered(value), :opaque}

      scalar?(value) ->
        {key, value, kind}

      true ->
        encoded = encode({key, value, kind})
        mode = if is_struct(encoded, Rendered) or is_struct(encoded, Comprehension), do: :opaque, else: :encoded
        {key, encoded, mode}
    end
  end

  # Only built-in scalar encoders are pure. Custom Safe implementations and
  # other opaque bindings are evaluated on every render, before comparison.
  defp scalar?(value), do: is_binary(value) or is_number(value) or is_atom(value)

  defp encode({_key, value, mode}) when mode in [:encoded, :opaque], do: value
  defp encode({_key, value, {:attribute, name}}), do: Filament.Web.attribute(name, value)
  defp encode({_key, value, :child}) when value in [nil, false], do: []
  defp encode({_key, value, :child}) when is_tuple(value) or is_list(value), do: Filament.Web.to_rendered(value)
  defp encode({_key, value, :child}), do: Safe.to_iodata(value)

  # A loop of components that render one shared template. LiveView matches
  # keyed rows by module and key, unkeyed rows by position.
  defp components([{:component, _, _, _, %Template{} = first} | _] = children) do
    keys = Enum.map(children, fn {:component, mod, _, key, _} -> if key not in [nil, false], do: {mod, key} end)
    keyed? = Enum.all?(keys)

    if Enum.all?(children, &shares_template?(&1, first)) and
         if(keyed?, do: unique?(keys), else: not Enum.any?(keys)) do
      comprehension(first, Enum.zip_with(keys, children, fn key, child -> entry(key, elem(child, 4)) end), keyed?)
    else
      Filament.Web.to_rendered({:fragment, children})
    end
  end

  defp components(children), do: Filament.Web.to_rendered({:fragment, children})

  defp shares_template?({:component, _, _, _, %Template{} = output}, first),
    do: output.static == first.static and output.bindings == first.bindings

  defp shares_template?(_child, _first), do: false

  # Rows of one compiled loop share a plan. LiveView matches keyed rows by
  # key and unkeyed rows by position. Rows that repeat a key render in place.
  defp rows([], _keyed?), do: Filament.Web.to_rendered({:fragment, []})

  defp rows([{_key, first} | _] = rows, keyed?) do
    if not keyed? or unique?(Enum.map(rows, &elem(&1, 0))) do
      comprehension(first, Enum.map(rows, fn {key, row} -> entry(key, row) end), keyed?)
    else
      Filament.Web.to_rendered({:fragment, Enum.map(rows, &elem(&1, 1))})
    end
  end

  defp unique?(keys), do: MapSet.size(MapSet.new(keys)) == length(keys)

  defp comprehension(first, entries, keyed?) do
    # LiveView tells a comprehension from a template only by fingerprint.
    fingerprint = Filament.Web.fingerprint({:comprehension, first.fingerprint})
    %Comprehension{static: first.static, fingerprint: fingerprint, has_key?: keyed?, entries: entries}
  end

  # LiveView keeps each entry's variables and passes the ones that changed,
  # with their previous values when composite; nested output is tracked
  # against its previous value.
  defp entry(key, template) do
    bindings = prepare(template)
    variables = Map.new(bindings, fn {key, value, mode} -> {key, {mode, value}} end)

    {key, variables, fn changed, track? -> Enum.map(bindings, &changed_binding(&1, changed, track?)) end}
  end

  defp changed_binding(binding, _changed, false), do: encode(binding)

  defp changed_binding({key, value, mode} = binding, changed, true) do
    case changed do
      %{^key => {:opaque, previous}} when mode == :opaque -> Filament.Web.track(value, previous)
      %{^key => _} -> encode(binding)
      _ -> nil
    end
  end
end
