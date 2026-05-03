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
    end
  end
end
