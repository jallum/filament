defmodule Filament.RenderContext do
  @moduledoc false

  @enforce_keys [:fiber_id, :fiber_tree]
  defstruct [
    # String.t() - current fiber being rendered
    :fiber_id,
    # %{String.t() => Filament.Fiber.t()} - full tree (read-only)
    :fiber_tree,
    props: %{},
    # Adapter chosen once by the host; the default preserves walked vnodes.
    target: Filament.VNode,
    # non_neg_integer() - current hook slot index
    hook_index: 0,
    # %{String.t() => Filament.Fiber.t()} - fibers rendered or rewalked this pass
    new_fibers: %{},
    # [String.t()] - ids of the current fiber's direct children, newest first
    children: [],
    # pid() | nil - the LiveView process that owns this render tree
    owner_pid: nil,
    # %{non_neg_integer() => term()} - accumulates new slot values written during render
    new_hook_slots: %{},
    # [{index, fiber_id, effect_fn, deps, old_cleanup}] - effects accumulated
    # during the pass, newest first
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
    # :subscribe | :current | :disconnected - how use_value reads sources;
    # a static (HTTP) render reads :current values or none
    sources: :subscribe,
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
          props: map(),
          target: module(),
          hook_index: non_neg_integer(),
          new_fibers: %{String.t() => Filament.Fiber.t()},
          children: [String.t()],
          owner_pid: pid() | nil,
          new_hook_slots: %{non_neg_integer() => term()},
          pending_effects: [{non_neg_integer(), String.t(), (-> term()), term(), (-> term()) | nil}],
          event_handler_index: non_neg_integer(),
          new_event_handlers: %{non_neg_integer() => {function(), Filament.Fiber.kinds()}},
          capture_handler_index: non_neg_integer(),
          new_capture_handlers: %{non_neg_integer() => {function(), Filament.Fiber.kinds()}},
          sources: :subscribe | :current | :disconnected,
          hook_slots: %{non_neg_integer() => term()},
          child_component_indices: %{module() => non_neg_integer()}
        }
end
