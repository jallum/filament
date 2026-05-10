defmodule Filament.RenderContext do
  @moduledoc false

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
    # %{non_neg_integer() => function()} - bubble-phase event handlers
    # registered this render
    new_event_handlers: %{},
    # non_neg_integer() - current capture-phase handler index (independent
    # slot space from event_handler_index)
    capture_handler_index: 0,
    # %{non_neg_integer() => function()} - capture-phase event handlers
    # registered this render
    new_capture_handlers: %{},
    # %{term() => pid()} - observable stubs for test isolation
    observable_stubs: %{},
    # boolean() - false during disconnected (HTTP) mounts to skip subscriptions
    subscribe_enabled: true,
    # String.t() | nil - session token for static→WS observable handoff
    session_token: nil,
    # %{non_neg_integer() => term()} - existing hook slot state for new child fibers
    hook_slots: %{},
    # %{module() => non_neg_integer()} - per-module counter for stable child fiber IDs.
    # Using a per-module counter means the Nth instance of a given component keeps a
    # stable ID regardless of how many other component types were rendered before it.
    child_component_indices: %{}
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
          capture_handler_index: non_neg_integer(),
          new_capture_handlers: %{non_neg_integer() => function()},
          observable_stubs: %{term() => pid()},
          subscribe_enabled: boolean(),
          session_token: String.t() | nil,
          hook_slots: %{non_neg_integer() => term()},
          child_component_indices: %{module() => non_neg_integer()}
        }
end
