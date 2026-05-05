defmodule Filament.Component do
  @moduledoc """
  Behaviour and macro for defining Filament components.

  Components are modules that implement the render/1 callback and can be
  composed together to build UIs. The defcomponent macro provides convenient
  syntax for prop declarations and validation.
  """

  @type props() :: map()
  @type rendered() :: Phoenix.LiveView.Rendered.t()

  @callback render(props()) :: rendered()

  @doc "Marker function to identify Filament components"
  @callback __filament_component__?() :: boolean()

  @doc "Returns component prop metadata"
  @callback __props__() :: keyword()

  @doc "Validates props map at runtime"
  @callback __validate_props__!(props()) :: :ok | no_return()

  @optional_callbacks [__validate_props__!: 1, __props__: 0]

  defmacro __using__(_opts) do
    quote do
      import Filament.Defcomponent
      import Filament.Hooks
      import Filament.SigilF

      Module.register_attribute(__MODULE__, :__macro_components__, accumulate: true)
      @before_compile Filament.Component
    end
  end

  defmacro __before_compile__(env) do
    macro_components = Module.get_attribute(env.module, :__macro_components__)

    if macro_components && macro_components != [] do
      grouped =
        Enum.group_by(
          macro_components,
          fn {mod, _data} -> mod end,
          fn {_mod, data} -> data end
        )

      quote do
        @doc false
        def __phoenix_macro_components__ do
          unquote(Macro.escape(grouped))
        end
      end
    end
  end
end
