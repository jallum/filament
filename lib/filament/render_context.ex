defmodule Filament.RenderContext do
  @moduledoc """
  Render context that lives in the process dictionary during component rendering.

  The context tracks the current fiber being rendered, the full fiber tree,
  the current hook index for stateful hooks, and any new fibers discovered
  during the render pass.
  """

  @enforce_keys [:fiber_id, :fiber_tree]
  defstruct [
    # String.t() - current fiber being rendered
    :fiber_id,
    # %{String.t() => Filament.Fiber.t()} - full tree (read-only)
    :fiber_tree,
    # non_neg_integer() - current hook slot index
    hook_index: 0,
    # %{String.t() => Filament.Fiber.t()} - fibers discovered this pass
    new_fibers: %{}
  ]

  @type t :: %__MODULE__{
          fiber_id: String.t(),
          fiber_tree: %{String.t() => Filament.Fiber.t()},
          hook_index: non_neg_integer(),
          new_fibers: %{String.t() => Filament.Fiber.t()}
        }
end
