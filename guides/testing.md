# Testing

Filament's test API mounts a component tree in-process with no browser,
no WebSocket, and no Phoenix endpoint. The result is tests that are:

- **Isolated** — each test owns its component instance; no shared state.
- **Fast** — typically under 5 ms per test.
- **Concurrent** — safe to run with `async: true`.

Add `:floki` to your test dependencies (it is not required in production):

```elixir
# mix.exs
{:floki, "~> 0.38", only: :test}
```

Then `import Filament.Test` in your test module and you have the full API.

## Mounting

```elixir
view = mount!(MyComponent, %{some_prop: "value"})
```

`mount!/3` renders the component, runs any mount effects, renders again
for state they set, and returns a `view`
struct containing `rendered_html`, a live `fiber_tree`, and stubs. `mount/3`
returns `{:ok, view}`. Both raise if the component does, as for a missing
required prop:

```elixir
assert_raise ArgumentError, ~r/required prop/, fn -> mount(MyComponent, %{}) end
```

## Interacting with the view

All interaction helpers follow the same pattern: find an element by CSS
selector, dispatch the corresponding event handler, flush state updates, and
return the re-rendered view.

### Bang variants and pipelines

Every helper has a bang variant that returns the view directly instead of
`{:ok, view}`. This enables pipelines — the idiomatic style for multi-step
interaction sequences:

```elixir
view =
  mount!(TodoList, %{})
  |> submit!("form", %{"text" => "Buy milk"})
  |> submit!("form", %{"text" => "Walk the dog"})
  |> click!(".todo-list li:first-child input[type=checkbox]")

assert render_text(view) =~ "Buy milk"
assert view.rendered_html =~ ~s(class="completed)
```

The non-bang forms return `{:ok, view} | {:error, reason}` and are useful when
you need to assert on errors:

```elixir
assert click(view, "#nonexistent") == {:error, {:no_element, "#nonexistent"}}
```

### Helper reference

| Helper | Triggers | Arguments |
|--------|----------|-----------|
| `click!(view, selector)` | `on_click` | CSS selector |
| `submit!(view, selector, params \\ %{})` | `on_submit` | selector, form data map |
| `change!(view, selector, params)` | `on_change` | selector, params map |
| `blur!(view, selector)` | `on_blur` | selector |
| `key_down!(view, key, opts \\ [])` | `on_key` (window-level) | key string, optional `ctrl: true` etc. |
| `key_down!(view, selector, key)` | `on_keydown` (element-scoped) | selector, key string |

`key_down!/3` dispatches to whichever form is appropriate based on the third
argument: a keyword list routes to the window-level `on_key` handler; a string
routes to the element-scoped `on_keydown` handler.

## Changing props

`put_props/2` merges new props into the mounted component's and renders it
again, as `Filament.LiveView.put_props/2` does in a view. Components keep
their state, so a test can check how a component takes a prop change
without a wrapper component to drive it:

```elixir
view =
  mount!(Exclude, %{id: 13})
  |> put_props(excluded: true)

assert render_text(view) =~ "Excluded"
```

## Asserting on output

```elixir
# Plain text content (tags stripped)
assert render_text(view) =~ "Count: 3"

# CSS class presence
assert has_class?(view, ".submit-btn", "disabled")
refute has_class?(view, ".submit-btn", "loading")

# Raw HTML for structure assertions
assert view.rendered_html =~ ~s(data-id="42")
```

`has_class?/3` raises if the selector matches no elements, which surfaces
selector typos as loud failures rather than silent `false` returns.

## Keyboard events

`on_key` is Filament's window-level keyboard binding. Handlers receive the key
string and a `%Filament.KeyModifiers{}` struct, letting you pattern-match on
both simultaneously:

```elixir
defcomponent CommandPalette do
  def render(_assigns) do
    {open, set_open} = use_state(false)

    ~F"""
    <div on_key={fn
      "k", %{ctrl: true} -> set_open.(true)
      "Escape", _        -> set_open.(false)
      _, _               -> :ignore
    end}>
      {if open do}
        <div class="palette">...</div>
      {end}
    </div>
    """
  end
end
```

Testing keyboard interactions is one line per key press:

```elixir
test "Ctrl+K opens the palette, Escape closes it" do
  view =
    mount!(CommandPalette, %{})
    |> key_down!("k", ctrl: true)

  assert render_text(view) =~ "palette"

  view = key_down!(view, "Escape")
  refute render_text(view) =~ "palette"
end
```

Modifier options: `ctrl: true`, `shift: true`, `alt: true`, `meta: true`.
Unspecified modifiers default to `false`.

## Observable stubs

Components whose domain hooks call `use_value` need a server to subscribe
to. In tests, start an in-process stub via `Filament.Test.Stub.start/1`
and pass its pid as the domain handle:

```elixir
alias Filament.Test.Stub

test "shows item count" do
  state = %Cart.State{items: [%Cart.Item{id: "a", quantity: 3}]}
  {:ok, stub} = Stub.start(fn _req -> state end)

  view = mount!(CartBadge, %{cart: stub})

  assert view.rendered_html =~ ~s(data-count="3")
end
```

`Stub.start/1` takes a 1-arity function that returns the initial state
(its argument is always `nil`). It
returns `{:ok, pid}` where the pid implements the same
`Filament.Cell` callbacks as `Filament.Observable.GenServer` — so any
component that subscribes via `use_value/2` receives the stub's
state.

### Stubbing a server the component also calls

Passing the stub as the prop replaces the server everywhere the prop goes.
When the component also calls the server, for reads or actions, keep the
real server in the props and answer only its subscriptions from the stub
with the `:cells` option:

```elixir
test "shows the scanning phase" do
  {:ok, stub} = Stub.start(fn _req -> {:loading, %{phase: :scanning}} end)

  view = mount!(QueuePage, %{catalog: catalog}, cells: %{catalog => stub})

  assert render_text(view) =~ "Scanning"
end
```

The key is the server as the source holds it: the pid, name or
`{:via, ...}` tuple the domain hook passes to `cell/1`. Every
`Filament.Observable.GenServer` source for that server, in any component
of the view, subscribes to the stub, and `Stub.push/2` updates them.

### Pushing updates

`Filament.Test.Stub.push/2` sends a new value to a stub, simulating a
server's `notify_observers/1` call. Call `Filament.Test.update/1`
afterward to drain the resulting `:cell_update` message and re-render.
`update/1` renders until nothing is left to apply, so state set by the
render's effects shows too; events such as `click!/2` do the same. Keep the
view it returns: its messages are gone from the mailbox.

```elixir
test "re-renders when server state changes" do
  {:ok, stub} = Stub.start(fn _req -> %Cart.State{} end)
  view = mount!(CartBadge, %{cart: stub})

  assert view.rendered_html =~ ~s(data-count="0")

  item = %Cart.Item{id: "a", quantity: 2}
  Stub.push(stub, Cart.State.add_item(%Cart.State{}, item))
  view = Filament.Test.update(view)

  assert view.rendered_html =~ ~s(data-count="2")
end
```

## Waiting for the view with await/3

Some state changes happen asynchronously — a spawned process, a delayed
`notify_observers`, an effect with a timer. `await/3` applies Filament
messages as they arrive and returns the view once its condition holds:

```elixir
test "count updates after async server push" do
  {:ok, stub} = Stub.start(fn _req -> %Cart.State{} end)
  view = mount!(CartBadge, %{cart: stub})

  spawn(fn ->
    Process.sleep(50)
    Stub.push(stub, Cart.State.add_item(%Cart.State{}, %Cart.Item{id: "a"}))
  end)

  view = await(view, &(&1.rendered_html =~ ~s(data-count="1")), timeout: 500)
  assert render_text(view) =~ "1 item"
end
```

It checks the condition again on each message, and every `interval:` ms
(default 50) for a condition on something other than the view. A view
renders only for Filament messages, so a value a render reads from
elsewhere shows once something it subscribes to changes. On timeout
(`timeout:`, default 1000 ms) it raises with the view's text.

`eventually/2` waits the same way for conditions that aren't about a
view, such as a server's state. It retries a function until it returns a
truthy value without a failing `assert`, and on timeout raises the last
assertion's error:

```elixir
eventually(fn -> assert ReadModel.lookup(:toy, 2) == {"two", 1} end)
```

## Putting it together — a complete example

```elixir
defmodule MyApp.CommandPaletteTest do
  use ExUnit.Case, async: true
  import Filament.Test

  alias MyApp.Components.CommandPalette

  test "closed on mount" do
    view = mount!(CommandPalette, %{})
    refute render_text(view) =~ "Search commands"
  end

  test "Ctrl+K opens, Escape closes" do
    view =
      mount!(CommandPalette, %{})
      |> key_down!("k", ctrl: true)

    assert render_text(view) =~ "Search commands"

    view = key_down!(view, "Escape")
    refute render_text(view) =~ "Search commands"
  end

  test "clicking a result fires on_select and closes" do
    test_pid = self()

    view =
      mount!(CommandPalette, %{on_select: fn cmd -> send(test_pid, {:selected, cmd}) end})
      |> key_down!("k", ctrl: true)
      |> click!(".result:first-child")

    assert_receive {:selected, _}
    refute render_text(view) =~ "Search commands"
  end
end
```
