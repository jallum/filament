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
    new_fibers: %{},
    # pid() | nil - the LiveView process that owns this render tree
    owner_pid: nil,
    # %{non_neg_integer() => term()} - accumulates new slot values written during render
    new_hook_slots: %{},
    # [{index, effect_fn, deps}] - effects accumulated during render
    pending_effects: [],
    # non_neg_integer() - current event handler index
    event_handler_index: 0,
    # %{non_neg_integer() => function()} - event handlers registered this render
    new_event_handlers: %{},
    # %{term() => pid()} - observable stubs for test isolation
    observable_stubs: %{},
    # boolean() - false during disconnected (HTTP) mounts to skip subscriptions
    subscribe_enabled: true,
    # %{non_neg_integer() => term()} - existing hook slot state for new child fibers
    hook_slots: %{}
  ]

  @type t :: %__MODULE__{
          fiber_id: String.t(),
          fiber_tree: %{String.t() => Filament.Fiber.t()},
          hook_index: non_neg_integer(),
          new_fibers: %{String.t() => Filament.Fiber.t()},
          owner_pid: pid() | nil,
          new_hook_slots: %{non_neg_integer() => term()},
          pending_effects: [{non_neg_integer(), (-> (-> :ok) | nil), term() | :no_deps}],
          event_handler_index: non_neg_integer(),
          new_event_handlers: %{non_neg_integer() => function()},
          observable_stubs: %{term() => pid()},
          subscribe_enabled: boolean(),
          hook_slots: %{non_neg_integer() => term()}
        }
end
