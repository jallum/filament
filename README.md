# Filament

Filament is a component and state-management layer for Phoenix LiveView. It
brings a JSX-like component model, React-style hooks, and observable GenServers
to Elixir — so you can build rich real-time UIs without spreading state across
socket assigns, `handle_event` callbacks, and manual PubSub wiring.

```elixir
defmodule CartWeb.Hooks do
  import Filament.Hooks, only: [use_source: 2, use_value: 2]

  # The factory and its identity live in one domain hook.
  def use_cart(cart_ref) do
    case use_source(fn -> Cart.Server.cell(cart_ref) end, cart_ref) do
      nil -> nil
      source -> source.data
    end
  end

  def use_cart_count(cart_ref) do
    cart = use_cart(cart_ref)
    source = if cart, do: Filament.Source.new(Filament.Observable.GenServer, cart)

    use_value(source, fn
      :disconnected -> 0
      state -> Cart.State.item_count(state)
    end)
  end
end

defmodule CartWeb.Components.CartBadge do
  use Filament.Component
  import CartWeb.Hooks

  defcomponent do
    prop(:cart, :any, required: true)

    def render(%{cart: cart}) do
      count = use_cart_count(cart)
      ~F"<span class=\"badge\">{count} items</span>"
    end
  end
end

# A parent passes session_id to children and calls
# Cart.Server.add_item(session_id, item) in event handlers.
```

## What it does

**JSX-like templates.** The `~F` sigil compiles HTML templates with
`{expression}` interpolation, `{for item <- list do}…{end}` loops, and
`<MyComponent prop={value} />` child component tags — the same mental model as
JSX, in Elixir. Inline markup between a component's tags becomes its
`children` prop: `<Page><h1>{title}</h1></Page>`. The wrapper renders it with
`{children}`, just like any other prop.

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
`use Filament.Observable.GenServer` and put the subscription in a custom hook
using `use_value/2`. Call `notify_observers(new_state)` after a mutation and
every subscribed component re-renders automatically — no PubSub, no
`handle_info` wiring in the LiveView.

Because the initial HTTP render reads each source's current value, the page
arrives with real server data already in the HTML — no loading spinners, no
client-side fetch on first paint. The HTTP render doesn't subscribe; the
WebSocket process subscribes on mount. Set `static_subscribe: false` on a
LiveView to skip reading sources during the HTTP render and show the
`:disconnected` fallback until the WebSocket connects.

**Projections and change-or-bust.** A custom hook passes a projection function
to `use_value/2` to extract only the slice of state the component
cares about. The function receives `:disconnected` or the raw server state and
runs on the client when an update arrives and is refreshed on every render, so it
can safely close over local component state such as filters or selections. If every
projected value is unchanged (`===`), the component does not re-render. The latest
raw state is retained for the next render, including local filter changes. This
keeps large UIs fast without manual shouldComponentUpdate logic.

```elixir
# CartBadge reads its domain value without handling a Source.
count = use_cart_count(cart)
```

**Renders follow inputs.** A component renders only when its props change
(`!==`), its own state changes, or a value it reads with `use_value` changes.
A parent's render reuses every child whose props are unchanged, and a
child's update renders that child alone. Closures passed as props compare
equal when they capture equal values, so callbacks need no memoization.

**Composable custom hooks.** Any function that calls `use_state`,
`use_source`, `use_value`, or `use_effect` is a custom hook. Domain behaviour — holds,
presence, pagination, debounce — lives in a plain module function rather than
scattered across mount/event/info callbacks.

```elixir
# examples/inventory — use_hold composes use_value + use_state
{held_qty, item, hold, release} = use_hold(server, item_id)
```

**Effects with cleanup.** `use_effect/2` runs a side effect after render, with
optional cleanup on re-run or unmount and dependency-based re-execution.

**Incremental adoption.** Start with `Filament.LiveComponent` to drop a
Filament component tree into any existing LiveView. Promote to
`Filament.LiveView` when you are ready — no big-bang rewrite required.

**Fast, isolated tests.** Filament's test API mounts a component tree
in-process with no browser or WebSocket needed. Tests run with `async: true`
and finish in milliseconds. Bang helpers and pipelines keep multi-step tests
readable:

```elixir
view =
  mount!(TodoWeb.Components.TodoList, %{})
  |> submit!("form", %{"text" => "Buy milk"})
  |> submit!("form", %{"text" => "Walk the dog"})
  |> click!(".todo-list li:first-child input[type=checkbox]")

assert render_text(view) =~ "Buy milk"
assert view.rendered_html =~ ~s(class="completed)
```

**Keyboard bindings with `on_key`.** Attach window-level keydown handlers
directly in the template. The handler receives the key string and a
`%Filament.KeyModifiers{}` struct — pattern-match on both at once, with no
JavaScript configuration required:

```elixir
~F"""
<div on_key={fn
  "k", %{ctrl: true} -> set_open.(true)
  "Escape", _        -> set_open.(false)
  _, _               -> :ignore
end}>
  {if open, do: render_palette()}
</div>
"""
```

Testing keyboard interactions is as clean as any other event:

```elixir
view =
  mount!(CommandPalette, %{})
  |> key_down!("k", ctrl: true)

assert render_text(view) =~ "Search commands"

view = key_down!(view, "Escape")
refute render_text(view) =~ "Search commands"
```

## Installation

```elixir
# mix.exs
{:filament, "~> 0.5"}
```

## Examples

| Example | What it demonstrates |
|---------|----------------------|
| `examples/todo` | `defcomponent`, `use_state`, a custom `use_todos` hook, rung-2 tests |
| `examples/cart` | Shared session identity, domain hooks, projections, rung-3 integration tests |
| `examples/inventory` | Custom `use_hold` hook, `handle_unsubscribe` auto-release, per-item projections |
| `examples/collaboration` | Custom `use_document` hook, real-time presence UI |

## Guides

- [Getting Started](guides/getting-started.md) — `defcomponent`, props, `use_state`, events, testing
- [Testing](guides/testing.md) — bang helpers, pipelines, observable stubs, keyboard events, async assertions
- [Observables](guides/observables.md) — `Observable.GenServer`, `use_source` / `use_value`, projections
- [Hooks](guides/hooks.md) — built-in hooks, `use_effect`, composing custom hooks
- [Migration Guide](guides/migration-guide.md) — incrementally adopting Filament in an existing LiveView app
