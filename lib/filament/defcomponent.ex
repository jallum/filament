defmodule Filament.Defcomponent do
  @moduledoc """
  The defcomponent macro implementation.

  Supports two forms:
    * `defcomponent do: block` - inferred name from parent module (for single-component modules)
    * `defcomponent Name do: block` - explicit name (for multi-component modules)

  ## Inferred Name Form

  When a module defines exactly one component with the inferred form, the component
  takes the name of the parent module:

      defmodule TodoWeb.Components.FilterBar do
        use Filament.Component

        defcomponent do
          prop(:filters, :list, required: true)
          # ...
        end
      end

  This allows using the component as `TodoWeb.Components.FilterBar` instead of
  `TodoWeb.Components.FilterBar.FilterBar`.

  ## Explicit Name Form

  Use the explicit form when defining multiple components in one module:

      defmodule MyComponents do
        use Filament.Component

        defcomponent Button do
          # ...
        end

        defcomponent Input do
          # ...
        end
      end

  Components are accessed as `MyComponents.Button` and `MyComponents.Input`.
  """

  defmacro __using__(_opts) do
    quote do
      import Filament.Defcomponent

      # Track whether this module has an inferred-name component
      Module.put_attribute(__MODULE__, :__filament_inferred__, false)
      # Track explicit-name submodules
      Module.register_attribute(__MODULE__, :__filament_explicit__, accumulate: true)
    end
  end

  # Inferred name form: defcomponent do: block
  defmacro defcomponent(do: block) do
    quote do
      Module.register_attribute(__MODULE__, :filament_props, accumulate: true)
      Module.register_attribute(__MODULE__, :filament_slots, accumulate: true)

      @behaviour Filament.Component

      unquote(block)

      @before_compile Filament.Defcomponent
    end
  end

  # Explicit name form: defcomponent Name do: block
  defmacro defcomponent(name, do: block) do
    quote do
      @__filament_explicit__ unquote(name)

      defmodule unquote(name) do
        @behaviour Filament.Component

        Module.register_attribute(__MODULE__, :filament_props, accumulate: true)
        Module.register_attribute(__MODULE__, :filament_slots, accumulate: true)
        Module.register_attribute(__MODULE__, :__macro_components__, accumulate: true)
        @before_compile Filament.Component

        unquote(block)

        @before_compile Filament.Defcomponent
      end
    end
  end

  defmacro prop(name, type, opts \\ []) do
    quote do
      @filament_props {unquote(name), unquote(type), unquote(opts)}
    end
  end

  defmacro slot(name, opts \\ []) do
    quote do
      @filament_slots {unquote(name), unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    module = env.module
    props = Module.get_attribute(module, :filament_props)
    slots = Module.get_attribute(module, :filament_slots) |> Enum.reverse()
    check_slot_prop_collisions!(module, props, slots)
    build_component_module_ast(module, props, slots)
  end

  defp check_slot_prop_collisions!(module, props, slots) do
    prop_names = for {name, _type, _opts} <- props, do: name

    for {slot_name, _opts} <- slots, slot_name in prop_names do
      raise CompileError,
        description:
          "slot #{inspect(slot_name)} has the same name as a prop in #{inspect(module)}"
    end
  end

  defp build_component_module_ast(module, props, slots) do
    quote do
      @props unquote(Macro.escape(build_props_metadata(props)))
      @slots unquote(Macro.escape(build_slots_metadata(slots)))

      def __filament_component_name__, do: unquote(module)

      def __filament_component__?, do: true

      def __props__, do: @props

      def __slots__, do: @slots

      def __validate_props__!(props) when is_map(props) do
        unquote(build_validation_code(props, slots))
        :ok
      end

      unquote(build_typespec(props))

      if !Module.defines?(__MODULE__, {:render, 1}) do
        raise CompileError,
          description: "defcomponent #{inspect(__MODULE__)} must define render/1"
      end
    end
  end

  defp build_props_metadata(props) do
    for {name, type, opts} <- props do
      required = Keyword.get(opts, :required, false)
      default = Keyword.get(opts, :default, :__NO_DEFAULT__)

      {name, %{type: type, required: required, default: default}}
    end
  end

  defp build_slots_metadata(slots) do
    for {name, opts} <- slots do
      %{
        name: name,
        required: Keyword.get(opts, :required, false),
        default: Keyword.get(opts, :default, nil)
      }
    end
  end

  defp build_validation_code(props, slots) do
    required_props =
      for {name, _type, opts} <- props,
          Keyword.get(opts, :required, false),
          do: name

    required_slots =
      for {name, opts} <- slots,
          Keyword.get(opts, :required, false),
          do: name

    prop_checks =
      Enum.map(required_props, fn name ->
        quote do
          if !Map.has_key?(props, unquote(name)) do
            raise ArgumentError,
                  "required prop #{inspect(unquote(name))} missing from #{inspect(props)}"
          end
        end
      end)

    slot_checks =
      Enum.map(required_slots, fn name ->
        quote do
          case Map.get(props, unquote(name), []) do
            [] ->
              raise ArgumentError,
                    "required slot #{inspect(unquote(name))} missing from #{inspect(props)}"

            _ ->
              :ok
          end
        end
      end)

    prop_checks ++ slot_checks
  end

  defp build_typespec(_props) do
    # Simplified typespec - in production would generate proper field types
    quote do
      @type props() :: map()
    end
  end
end
