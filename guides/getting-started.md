# Getting Started

Filament is a process-aware UI framework for Phoenix LiveView that brings
React-style component composition and hooks to your Elixir applications. This
guide walks you through building a working TodoList component — the same one
in the `examples/todo` directory — so you understand `defcomponent`, props,
`use_state`, event closures, child components, and how to test everything with
Filament's rung-2 isolation API. By the end you will have a passing test suite
and a clear mental model of the Filament component lifecycle.

## What you need

- Elixir 1.17+ and Phoenix LiveView 1.0+
- Add Filament to your project:

```elixir
# mix.exs
{:filament, "~> 0.1"}
```

- Run `mix deps.get` and then `use Filament.Component` in any module where you
  want to define components.

## Defining a component

Every Filament component lives inside a `defcomponent` block. Here is the real
`TodoItem` component from `examples/todo`:

```elixir
defmodule TodoWeb.Components.TodoItem do
  use Filament.Component

  defcomponent do
    prop(:todo, :map, required: true)
    prop(:on_toggle, :function, default: nil)
    prop(:on_remove, :function, default: nil)

    defp item_class(%{completed: true}), do: "completed"
    defp item_class(_), do: ""

    def render(%{todo: todo, on_toggle: on_toggle, on_remove: on_remove}) do
      ~F"""
      <li class={item_class(todo)}>
        <div class="view">
          <input
            class="toggle"
            type="checkbox"
            checked={todo.completed}
            on_click={on_toggle}
          />
          <label>{todo.text}</label>
          <button class="destroy" on_click={on_remove}>×</button>
        </div>
      </li>
      """
    end
  end
end
```

Key points:

- `use Filament.Component` imports `defcomponent`, `prop`, the `~F` sigil, and
  all hooks into your module.
- `prop(:name, :type, opts)` declares a typed attribute. Pass `required: true`
  to make the prop mandatory or `default: value` to make it optional.
- `render/1` receives a plain map of props — pattern-match directly.
- Inside `~F""" ... """`, use `{expression}` for interpolation and `@prop_name`
  as a shorthand for the same — both resolve to local variables, not an assigns
  map.
- Event attributes like `on_click={handler}` accept zero-arity or one-arity
  functions; Filament wires them to `phx-click` automatically.

## Local state with use_state

`use_state/1` gives a component a piece of mutable local state. The
`TodoList` component uses it to track the active filter:

```elixir
def render(%{title: title}) do
  store = use_observable(fn -> Todo.Store.start_link([]) end)
  todos = use_observable(store, fn :disconnected -> []; s -> s end)

  {filter, set_filter} = use_state(:all)
  filtered = apply_filter(todos, filter)
  # ...
end
```

- `use_state(initial)` returns `{current_value, setter}`.
- On the first render, `current_value` is `initial`. On subsequent renders it
  is whatever was last passed to `setter.(new_value)`.
- Calling `setter.(new_value)` sends a message to the owning LiveView, which
  triggers a re-render of only the affected fiber.
- **Rules of hooks**: call `use_state` (and all hooks) at the top level of
  `render/1`, never inside `if`, `case`, or comprehensions. Hook identity
  depends on call order.

## Event closures

All Filament event handlers are plain Elixir closures attached to `on_*`
template attributes. The `on_*` name maps directly to the corresponding
Phoenix event: `on_click` → `phx-click`, `on_submit` → `phx-submit`,
`on_change` → `phx-change`, and so on. Filament wires the closure to a
`filament:fiber_id:index` ref automatically — you never write wire format by
hand.

The `TodoList` component handles form submission and item interactions
entirely through closures:

```elixir
{text, set_text} = use_state("")

~F"""
<form on_submit={fn %{"text" => val} ->
  if String.trim(val) != "", do: Todo.Store.add(store, val)
  set_text.("")
end}>
  <input name="text" class="new-todo" value={text} placeholder="What needs to be done?" />
</form>

<ul class="todo-list">
  {for todo <- filtered do}
    <TodoItem
      todo={todo}
      on_toggle={fn -> Todo.Store.toggle(store, todo.id) end}
      on_remove={fn -> Todo.Store.remove(store, todo.id) end}
    />
  {end}
</ul>
"""
```

- Zero-arity closures receive no arguments; one-arity closures receive the
  event params map (for `on_submit`, the full form data; for `on_change`, the
  changed field map including `_target`).
- Closures capture the render-time environment. `todo.id` in the loop above is
  correctly bound per iteration, and `set_text` from `use_state` is in scope
  inside `on_submit`.
- Because closures own both the side effect and any state updates, there is no
  `handle_event` callback to write — the closure is the handler.

### Keyboard events with on_key

`on_key` binds a window-level keydown listener to any element. The handler
receives two arguments: the key string and a `%Filament.KeyModifiers{}` struct
containing the modifier state. This lets you pattern-match cleanly on both the
key and modifiers together:

```elixir
~F"""
<div on_key={fn
  "Escape", _              -> close_modal()
  "s",      %{ctrl: true}  -> save()
  "?",      _              -> show_help()
  _,        _              -> :ignore
end}>
  {children}
</div>
```

`%Filament.KeyModifiers{}` has fields `ctrl`, `shift`, `alt`, and `meta`, all
defaulting to `false`. Unspecified fields are ignored in a pattern match, so
`%{ctrl: true}` matches any combination that includes Ctrl held down.

Under the hood, Filament injects a `FilamentKey` Phoenix LiveView hook via a
`<script data-phx-runtime-hook>` tag in `Filament.LiveView.render/1`. No
JavaScript configuration or `liveSocket` hook registration is required — it
activates automatically whenever you use `on_key`.

**Full event attribute reference:**

| Attribute     | Phoenix event      | Handler arity / arguments                          |
|---------------|--------------------|----------------------------------------------------|
| `on_click`    | `phx-click`        | 0-arity or 1-arity `(params)`                      |
| `on_submit`   | `phx-submit`       | 1-arity `(params)` — full form data map            |
| `on_change`   | `phx-change`       | 1-arity `(params)` — changed field map             |
| `on_blur`     | `phx-blur`         | 0-arity or 1-arity `(params)`                      |
| `on_keydown`  | `phx-keydown`      | 1-arity `(params)` — `%{"key" => key_string, ...}` |
| `on_key`      | `FilamentKey` hook | 2-arity `(key :: String.t(), %Filament.KeyModifiers{})` |

## Composing components and keyed lists

Child components are rendered with their module name as a tag in `~F` templates:

```elixir
~F"""
<section class="main">
  <ul class="todo-list">
    {for todo <- filtered do}
      <TodoItem
        todo={todo}
        on_toggle={fn -> Todo.Store.toggle(store, todo.id) end}
        on_remove={fn -> Todo.Store.remove(store, todo.id) end}
      />
    {end}
  </ul>
</section>
"""
```

- `<TodoItem prop={value} />` passes props to the child component exactly like
  HTML attributes.
- Each iteration of the `for` loop creates a separate fiber tracked by position
  (index). For lists that can be reordered or have items deleted, add a `:key`
  attribute:

  ```elixir
  <TodoItem :key={todo.id} todo={todo} on_toggle={...} on_remove={...} />
  ```

  Without `:key`, Filament matches children by position; removing an item in
  the middle shifts all subsequent fibers. With `:key={todo.id}`, Filament
  matches by identity and cleanly unmounts only the removed item.

## Testing with Filament.Test

Filament's test API mounts a component tree in-process — no browser, no
WebSocket, no endpoint. Tests run with `async: true` and finish in
milliseconds.

```elixir
defmodule Todo.Test do
  use ExUnit.Case, async: true
  import Filament.Test

  test "renders todo items after submission" do
    view =
      mount!(TodoWeb.Components.TodoList, %{})
      |> submit!("form", %{"text" => "First task"})
      |> submit!("form", %{"text" => "Second task"})

    assert render_text(view) =~ "First task"
    assert render_text(view) =~ "Second task"
  end
end
```

Bang variants (`mount!`, `click!`, `submit!`, `change!`, `blur!`, `key_down!`)
unwrap `{:ok, view}` and raise on error, enabling pipelines. Use the non-bang
forms when asserting on errors.

See the **[Testing guide](testing.html)** for the full API reference:
observable stubs, async assertions, keyboard events, and more.

## Next steps

- **[Testing guide](testing.html)** — full test API reference: bang/pipeline helpers, observable stubs, async assertions, keyboard events.
- **[Observables guide](observables.html)** — `Observable.GenServer`, `use_observable/1` and `use_observable/2`, and the change-or-bust pattern.
- **[Hooks guide](hooks.html)** — composing built-in hooks and writing custom hooks for domain logic.
- **API reference** — see `Filament.Hooks` for the full hook signatures and `Filament.Component` for the behaviour callbacks.
