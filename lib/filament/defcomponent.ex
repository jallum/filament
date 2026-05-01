defmodule Filament.Defcomponent do
  @moduledoc """
  The defcomponent macro implementation.
  """

  defmacro __using__(_opts) do
    quote do
      import Filament.Defcomponent
    end
  end

  defmacro defcomponent(name, do: block) do
    quote do
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
    props = Module.get_attribute(env.module, :filament_props)

    quote do
      @props unquote(Macro.escape(build_props_metadata(props)))

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
