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

`mount!/3` renders the component, runs any mount effects, and returns a `view`
struct containing `rendered_html`, a live `fiber_tree`, and stubs. It raises if
mounting fails.

Use the non-bang `mount/3` when you need to assert on a failure:

```elixir
assert {:error, reason} = mount(MyComponent, %{bad: :props})
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

Components that call `use_value` need a server to subscribe to. In tests,
supply a stub instead of a real process:

```elixir
test "shows item count" do
  view =
    mount!(CartBadge, %{server: :cart},
      stub: [{:cart, fn _req -> %{items: ["a", "b", "c"]} end}]
    )

  assert render_text(view) =~ "3 items"
end
```

The stub function receives the subscription request and returns the initial
state. Stubs are identified by any term — atoms work well.

### Pushing updates

`Filament.Test.Stub.push/2` sends a new value to a stub, simulating a server
`notify_observers/1` call. Call `Filament.Test.update/1` afterward to flush the
message and re-render:

```elixir
test "re-renders when server state changes" do
  {:ok, view} =
    mount(CartBadge, %{server: :cart},
      stub: [{:cart, fn _req -> %{items: []} end}]
    )

  assert render_text(view) =~ "0 items"

  Filament.Test.Stub.push(view.stubs[:cart], %{items: ["a", "b"]})
  view = Filament.Test.update(view)

  assert render_text(view) =~ "2 items"
end
```

Note: `mount/3` (non-bang) is used here so `view.stubs` is accessible before
entering the pipeline.

## Async assertions with eventually/2

Some state changes happen asynchronously — a spawned process, a delayed
`notify_observers`, an effect with a timer. `eventually/2` retries an assertion
until it passes or a timeout is reached:

```elixir
test "count updates after async server push" do
  {:ok, view} = mount(CartBadge, %{server: :cart},
    stub: [{:cart, fn _req -> %{items: []} end}]
  )

  spawn(fn ->
    Process.sleep(50)
    Filament.Test.Stub.push(view.stubs[:cart], %{items: ["a"]})
  end)

  Filament.Test.eventually(fn ->
    view = Filament.Test.update(view)
    render_text(view) =~ "1 item"
  end, timeout: 500)
end
```

Options: `timeout:` (ms, default 1000), `interval:` (retry interval ms,
default 50).

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
