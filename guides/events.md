# Events

Filament's event model is a target-agnostic capture/bubble walker over the
fiber tree. Backends contribute event sources — DOM events for the web
adapter, terminal escape sequences for TUI, hardware interrupts for
embedded — and feed them into `Filament.Core.dispatch_event/4`. Event
*semantics* (the ancestor walk, propagation control, handler arity) live
in Core; the backend only knows how to source events.

This guide is for two audiences: **backend authors** wiring a new
rendering target into Filament's event surface, and **component
developers** who want capture-phase handlers (rare; usually `on_*` =
bubble is enough).

## Component developer perspective

Most component code only ever uses bubble-phase handlers — `on_click`,
`on_submit`, `on_change`, etc. — and doesn't think about phases at all.
The `on_*` template attribute syntax registers a bubble handler at a
fresh slot on the component's fiber.

Capture-phase handlers fire on **ancestor fibers** before a descendant's
target handler runs. They're useful for cross-cutting concerns that
should intercept events without each child opting in:

- A modal trapping `Escape` so parents below can't see it.
- A focus manager re-routing arrow keys.
- An analytics layer logging clicks.

Today the registration API is `Filament.Hooks.event_at(slot, handler,
:capture)` directly — there's no `on_click_capture=` template syntax yet
(that's a follow-up). Capture handlers receive the event params and may
call `Filament.Core.stop_propagation/1` to halt the walk:

```elixir
def render(_assigns) do
  on_capture = fn params ->
    if params.key == "Escape", do: Filament.Core.stop_propagation(:trapped)
  end

  Filament.Hooks.event_at(0, on_capture, :capture)

  ~F"""
  <div>
    {render_children()}
  </div>
  """
end
```

`stop_propagation/1` throws a tagged term the dispatcher catches; the
walker returns `{:ok, {:stopped, value}}` and no further handlers fire.

## Backend author perspective

A backend feeds events into Filament by:

1. Knowing which fiber is the **target** of the event. For the web, the
   wire ref `phx-click="filament:fiber:slot"` encodes target-fiber and
   target-slot — the LiveView adapter parses it. For TUI, the focus
   manager tracks which fiber currently holds focus; key events target
   that fiber.
2. Calling `Filament.Core.dispatch_event(tree, target_fiber, target_slot, params)`.

The walker:

1. **Capture phase.** Walks ancestors root → target's-parent. At each
   ancestor, every entry in `fiber.capture_handlers` runs (in slot order).
2. **Target phase.** The target's `event_handlers[target_slot]` runs.
3. **Stop propagation.** A handler can call
   `Filament.Core.stop_propagation(value)` to halt the walk.
   `dispatch_event` then returns `{:ok, {:stopped, value}}`.

`dispatch_event` returns:

- `{:ok, :dispatched}` — normal walk completed.
- `{:ok, {:stopped, value}}` — a handler called `stop_propagation`.
- `{:error, :no_target}` — target fiber not in the tree.

Side effects from handlers (state setters, observable writes) propagate
through Filament's runtime as usual; the dispatcher just runs the
handlers in the walk order.

### LiveView adapter as a worked example

`Filament.LiveView.dispatch_filament_event/3` is a thin shim: parse the
wire ref, hand off to `Filament.Core.dispatch_event/4`. The 2-arity
push-fn handler pattern (`use_event_ref`) stays on a parallel
LV-specific path because it needs socket access for
`Phoenix.LiveView.push_event` — that's a web concern that doesn't belong
in Core.

```elixir
def dispatch_filament_event(ref, params, socket) do
  [fiber_id, slot_str] = String.split(ref, ":", parts: 2)
  slot = String.to_integer(slot_str)
  tree = socket.assigns._filament_tree

  Filament.Core.dispatch_event(tree, fiber_id, slot, params)
  {:noreply, socket}
end
```

A TUI backend looks similar — the `target_fiber_id` comes from the focus
tracker rather than a wire ref, but the dispatcher call is the same.

## Handler shape

Handlers registered at `event_handlers[slot]` or `capture_handlers[slot]`
are 0-arity or 1-arity functions:

```elixir
# 0-arity — invoked with no args
fn -> Cart.add_item(server, product) end

# 1-arity — receives params
fn %{"text" => val} -> Todo.Store.add(store, val) end
```

The 2-arity form is reserved for the LV-specific `use_event_ref` push
pattern and isn't part of the Core dispatch path.

## Wire-ref format (web only)

For the web backend, `phx-click="filament:fiber_id:slot"` carries the
target-fiber and target-slot to the server. Capture-phase handlers
don't need wire refs — they fire from the dispatcher's ancestor walk
based on the *target's* fiber id. Only target handlers are wire-addressable.

This is the same model the DOM uses: `addEventListener('click', ..., {capture:
true})` doesn't expose a per-element click target — the listener fires
based on event flow, not on a routed identity.

## See also

- **`Filament.Core`** — `dispatch_event/4`, `stop_propagation/1`.
- **`Filament.Hooks`** — `event_at/3`, `register_event_handler/2`.
- **[Hooks guide](hooks.html)** — the broader hook system that
  `event_at/3` is part of.
