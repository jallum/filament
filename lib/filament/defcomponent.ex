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
      # Props for this component
      Module.register_attribute(__MODULE__, :filament_props, accumulate: true)

      @behaviour Filament.Component

      unquote(block)

      @before_compile Filament.Defcomponent
    end
  end

  # Explicit name form: defcomponent Name do: block
  defmacro defcomponent(name, do: block) do
    quote do
      # Track this explicit component
      @__filament_explicit__ unquote(name)

      defmodule unquote(name) do
        @behaviour Filament.Component

        Module.register_attribute(__MODULE__, :filament_props, accumulate: true)

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

  defmacro __before_compile__(env) do
    module = env.module

    # Check if this module has an inferred component by looking at props
    # (inferred components have props accumulated without explicit names)
    inferred =
      Module.get_attribute(module, :filament_props) != [] and
        Module.get_attribute(module, :__filament_explicit__) == []

    explicit = Module.get_attribute(module, :__filament_explicit__) || []
    props = Module.get_attribute(module, :filament_props)

    # Determine the component name function
    component_name =
      cond do
        inferred ->
          # Inferred: the component IS this module
          module

        explicit != [] ->
          # Explicit names exist: component is the current module
          module

        true ->
          # Fallback (shouldn't happen for valid components)
          module
      end

    quote do
      @props unquote(Macro.escape(build_props_metadata(props)))

      def __filament_component_name__, do: unquote(component_name)

      def __filament_component__?, do: true

      def __props__, do: @props

      def __validate_props__!(props) when is_map(props) do
        unquote(build_validation_code(props))
        :ok
      end

      unquote(build_typespec(props))

      # Enforce render/1 exists
      unless Module.defines?(__MODULE__, {:render, 1}) do
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

  defp build_validation_code(props) do
    required_props =
      for {name, _type, opts} <- props,
          Keyword.get(opts, :required, false),
          do: name

    Enum.map(required_props, fn prop ->
      quote do
        prop_name = unquote(prop)

        unless Map.has_key?(props, prop_name) do
          raise ArgumentError,
                "required prop #{inspect(prop_name)} missing from #{inspect(props)}"
        end
      end
    end)
  end

  defp build_typespec(_props) do
    # Simplified typespec - in production would generate proper field types
    quote do
      @type props() :: map()
    end
  end
end
