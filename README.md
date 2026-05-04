# Filament

Filament is a component and state-management layer for Phoenix LiveView. It
brings a JSX-like component model, React-style hooks, and observable GenServers
to Elixir — so you can build rich real-time UIs without spreading state across
socket assigns, `handle_event` callbacks, and manual PubSub wiring.

```elixir
defmodule CartWeb.Components.CartView do
  use Filament.Component

  defcomponent do
    prop(:cart_id, :string, required: true)

    def render(%{cart_id: cart_id}) do
      {_server, cart} = use_observable({:via, Registry, {Cart.Registry, cart_id}},
        disconnected: nil
      )

      ~F"""
      <div class="cart">
        <header>
          <CartBadge cart_id={cart_id} />
        </header>
        {if cart do}
          {for item <- cart.items do}
            <div class="item">
              <span>{item.name}</span>
              <button on_click={fn -> Cart.Server.remove(cart_id, item.id) end}>
                Remove
              </button>
            </div>
          {end}
        {end}
      </div>
      """
    end
  end
end

defmodule CartWeb.Components.CartBadge do
  use Filament.Component

  defcomponent do
    prop(:cart_id, :string, required: true)

    def render(%{cart_id: cart_id}) do
      {_server, count} = use_observable({:via, Registry, {Cart.Registry, cart_id}},
        project: &Cart.State.item_count/1,
        disconnected: 0
      )

      ~F"""
      <span class="badge">{count} items</span>
      """
    end
  end
end
```

## What it does

**JSX-like templates.** The `~F` sigil compiles HTML templates with
`{expression}` interpolation, `{for item <- list do}…{end}` loops, and
`<MyComponent prop={value} />` child component tags — the same mental model as
JSX, in Elixir.

**Components with typed props.** `defcomponent` declares a component with
`prop/3` — typed, validated, with required or default values. Each component
instance gets an isolated fiber with its own hook state and event handlers; no
more shared assign namespaces.

**Hooks for local state.** `use_state/1` gives a component a piece of mutable
local state that persists across re-renders without touching the LiveView
socket. Calling the setter re-renders only the affected fiber.

```elixir
{filter, set_filter} = use_state(:all)
```

**Observable GenServers.** Wrap any GenServer with
`use Filament.Observable.GenServer` and components can subscribe to it with
`use_observable/2`. Call `notify_observers(new_state)` after a mutation and
every subscribed component re-renders automatically — no PubSub, no
`handle_info` wiring in the LiveView.

**Projections and change-or-bust.** A subscriber can supply a `project:`
function that extracts only the slice of state it cares about. If the projected
value is unchanged after a mutation, the update is suppressed and the component
does not re-render. This keeps large UIs fast without manual shouldComponentUpdate
logic.

```elixir
# CartBadge only re-renders when the item count changes,
# not on every cart mutation.
{_server, count} = use_observable({:via, Registry, {Cart.Registry, cart_id}},
  project: &Cart.State.item_count/1
)
```

**Automatic memoization.** The `~F` compiler automatically wraps closure
expressions and child component renders in `memo_at` calls. Stable subtrees
skip re-evaluation without any annotation from the component author.

**Composable custom hooks.** Any function that calls `use_state`,
`use_observable`, or `use_effect` is a custom hook. Domain behaviour — holds,
presence, pagination, debounce — lives in a plain module function rather than
scattered across mount/event/info callbacks.

```elixir
# examples/inventory — use_hold composes use_observable + use_state
{held_qty, item, hold, release} = use_hold(server, item_id)
```

**Effects with cleanup.** `use_effect/2` runs a side effect after render, with
optional cleanup on re-run or unmount and dependency-based re-execution.

**Incremental adoption.** Start with `Filament.LiveComponent` to drop a
Filament component tree into any existing LiveView. Promote to
`Filament.LiveView` when you are ready — no big-bang rewrite required.

**Fast, isolated tests.** Filament's test API mounts a component tree
in-process with no browser or WebSocket needed. Tests run with `async: true`
and finish in milliseconds.

```elixir
{:ok, view} = mount(TodoWeb.Components.TodoList, %{})
{:ok, view} = submit(view, "form", %{"text" => "Buy milk"})
assert render_text(view) =~ "Buy milk"
```

## Installation

```elixir
# mix.exs
{:filament, "~> 0.1"}
```

## Examples

| Example | What it demonstrates |
|---------|----------------------|
| `examples/todo` | `defcomponent`, `use_state`, `use_observable` with factory fn, rung-2 tests |
| `examples/cart` | Observable.GenServer, projections, change-or-bust, rung-3 integration tests |
| `examples/inventory` | Custom `use_hold` hook, `handle_unsubscribe` auto-release, per-item projections |
| `examples/collaboration` | Multiple concurrent subscribers, real-time presence UI |

## Guides

- [Getting Started](guides/getting-started.md) — `defcomponent`, props, `use_state`, events, testing
- [Observables](guides/observables.md) — `Observable.GenServer`, `use_observable`, projections
- [Hooks](guides/hooks.md) — built-in hooks, `use_effect`, composing custom hooks
- [Migration Guide](guides/migration-guide.md) — incrementally adopting Filament in an existing LiveView app
