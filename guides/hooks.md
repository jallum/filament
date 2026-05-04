# Hooks

Hooks are functions you call at the top level of `render/1` to access state,
subscribe to servers, and schedule side effects. Filament ships three
application-facing hooks: `use_state`, `use_observable`, and `use_effect`. You
can compose these into custom hooks that encapsulate domain behaviour — the
inventory example's `use_hold` is a complete worked example of this pattern.

## Rules of hooks

Three rules apply to every hook call, built-in or custom:

1. **Call at the top level of `render/1`** — not inside `if`, `case`, `for`,
   or any other conditional or loop.
2. **Call in consistent order** — hook identity is determined by call order
   (slot index). A hook that is called on some renders but not others corrupts
   all subsequent hooks in that component.
3. **Only call during a render pass** — hooks read and write a
   `RenderContext` stored in the process dictionary. Calling one outside
   `render/1` raises an `ArgumentError`.

These are the same rules as React hooks, for the same reason: stability of
slot identity across renders.

## use_state

```elixir
{value, setter} = use_state(initial)
```

Returns the current state value and a stable setter closure. On the first
render of a fiber, `value` is `initial`. On subsequent renders it is whatever
was last passed to `setter.(new_value)`. The setter sends a message to the
owning LiveView process, which re-renders only the affected fiber.

```elixir
def render(%{title: title}) do
  {filter, set_filter} = use_state(:all)

  ~F"""
  <footer>
    <button on_click={fn -> set_filter.(:all)    end}>All</button>
    <button on_click={fn -> set_filter.(:active) end}>Active</button>
    <button on_click={fn -> set_filter.(:done)   end}>Done</button>
  </footer>
  """
end
```

Setters are safe to capture in closures — the same function is reused across
renders so you can compare them with `==` if needed.

## use_observable/1 and use_projection/3

The preferred pattern separates server resolution from value projection:

```elixir
server = use_observable(server_or_fn)
value  = use_projection(server, project_fn, opts \\ [])
```

`use_observable/1` resolves the server reference to a live pid and returns it.
Returns `nil` during disconnected (HTTP static) renders — no subscription is
created until the WebSocket connects.

`use_projection/3` subscribes this fiber's hook slot to the resolved server and
returns the projected value. When `server` is `nil` it returns the `:disconnected`
option (default `:disconnected`) without touching any server process.

The first argument to `use_observable/1` can be:

- a pid, atom, `{:via, Registry, key}`, or `{node, name}` — used directly.
- a zero-arity function — called on the first WebSocket render (and again if the
  process dies) to obtain a pid or `{:ok, pid}`; useful when the component owns
  the server lifecycle.

`use_projection/3` options:

- `:disconnected` — value returned when `server` is `nil` (default `:disconnected`).
- `:request` — passed to `handle_subscribe/3` on the server (default `nil`).

```elixir
# Connect to a running singleton server
server = use_observable(Cart.Server)
count  = use_projection(server, &Cart.State.item_count/1, disconnected: 0)

# Component owns the server lifecycle — keep the pid for mutations
store = use_observable(fn -> Todo.Store.start_link([]) end)
todos = use_projection(store, & &1, disconnected: [])

# Multiple projections from one server — one subscriber entry on the server
server = use_observable(DocumentServer.via_registry(doc_id))
title  = use_projection(server, & &1.title)
locked = use_projection(server, & &1.locked, disconnected: false)
```

Passing `server` as a prop to child components lets each child register its own
projection without creating redundant subscriber entries on the server.

### use_observable/2 (legacy)

`use_observable/2` with explicit opts is still supported for compatibility. It
combines resolution and subscription into one call and returns `{server, value}`:

```elixir
{_server, count} = use_observable(Cart.Server,
  project: &Cart.State.item_count/1,
  disconnected: 0
)
```

See the [Observables guide](observables.html) for the change-or-bust mechanism
and projection patterns.

## use_effect

```elixir
use_effect(fn -> cleanup_fn_or_nil end, deps)
```

Schedules a zero-arity function to run after the render completes. The
function may return a zero-arity cleanup function that is called before the
effect re-runs (when deps change) or when the fiber unmounts.

`deps` controls re-execution:

- `[]` — run once on mount, cleanup on unmount.
- `[dep1, dep2, ...]` — re-run whenever any dep changes (`Kernel.==`
  comparison); cleanup before re-run.
- `:always` — run on every render.

```elixir
use_effect(fn ->
  ref = Phoenix.PubSub.subscribe(MyApp.PubSub, "topic:#{id}")
  fn -> Phoenix.PubSub.unsubscribe(MyApp.PubSub, "topic:#{id}") end
end, [id])
```

## Composing hooks into custom hooks

Any module function that calls `use_state`, `use_observable`, or `use_effect`
is a custom hook. The only requirements are that it is called at the top level
of `render/1` and always calls the same hooks in the same order.

Custom hooks let you extract domain behaviour that would otherwise clutter
`render/1` and repeat across components.

### Example: use_hold (inventory example)

The inventory example (`examples/inventory/lib/inventory_web/hooks.ex`)
defines `use_hold/3` — a hook that manages quantity-based resource holds
against an `Inventory.Server`. It composes `use_observable`, `use_projection`,
and `use_state` and returns a tuple of the held quantity, current item state,
and `hold`/`release` closures:

```elixir
defmodule InventoryWeb.Hooks do
  import Filament.Hooks

  def use_hold(server, item_id, opts \\ []) do
    disconnected_val = Keyword.get(opts, :disconnected, :disconnected)
    sentinel = :__hold_disconnected__

    srv  = use_observable(server)
    item = use_projection(srv, &Map.get(&1, item_id), disconnected: sentinel)
    {held_qty, set_held_qty} = use_state(0)

    if item == sentinel do
      disconnected_val
    else
      owner_pid = current_context().owner_pid

      hold = fn qty ->
        case GenServer.call(server, {:filament_hold, item_id, qty, owner_pid}) do
          :ok -> set_held_qty.(held_qty + qty)
          {:error, reason} -> raise "hold denied for #{inspect(item_id)}: #{inspect(reason)}"
        end
      end

      release = fn qty ->
        GenServer.cast(server, {:filament_release_qty, item_id, qty, owner_pid})
        set_held_qty.(max(0, held_qty - qty))
      end

      {held_qty, item, hold, release}
    end
  end
end
```

Key points about this implementation:

- **`use_observable` with `:project`** — subscribes to the full inventory map
  but projects to a single item, so only updates to `item_id` trigger a
  re-render of this fiber.
- **`use_state`** — tracks held quantity locally; the server is the source of
  truth for availability but the component tracks its own portion of the hold.
- **`:disconnected` sentinel** — a private atom distinct from `nil` or `false`
  lets the hook distinguish "not yet connected" from "item not found", and
  return the caller's `disconnected:` value cleanly.
- **`current_context().owner_pid`** — the LiveView process pid, used as the
  hold owner so the server can release all holds when that process terminates
  (via `handle_unsubscribe/2`).

The hook is used from `InventoryItem` by importing the hooks module and
calling it at the top of `render/1`:

```elixir
defmodule InventoryWeb.Components.InventoryItem do
  use Filament.Component
  import InventoryWeb.Hooks

  defcomponent do
    prop(:item_id, :string, required: true)
    prop(:server, :any, required: true)

    def render(%{item_id: item_id, server: server}) do
      noop = fn _ -> :ok end

      {held_qty, item, hold, release} =
        use_hold(server, item_id, disconnected: {0, nil, noop, noop})

      ~F"""
      <div class="inventory-item">
        {if item do}
          <strong>{item.name}</strong>
          <span class="available">{item.available} available</span>
          {if held_qty > 0 do}
            <span class="held">Holding: {held_qty}</span>
            <button on_click={fn -> release.(1) end}>−</button>
          {end}
          {if item.available > 0 do}
            <button on_click={fn -> hold.(1) end}>+</button>
          {else}
            <span class="status out-of-stock">Out of Stock</span>
          {end}
        {end}
      </div>
      """
    end
  end
end
```

### Automatic release on disconnect

The hold release on disconnect is handled entirely in the server's
`handle_unsubscribe/2` callback, which `Observable.GenServer` calls when a
subscriber's LiveView process terminates. This means the hook itself does not
need to set up an `on_unmount` callback or `use_effect` for cleanup — the
server owns that contract:

```elixir
@impl Filament.Observable
def handle_unsubscribe(subscriber, state) do
  case Map.pop(state.holds, subscriber.pid) do
    {nil, _} ->
      {:ok, state}

    {holder_holds, new_holds} ->
      new_items =
        Enum.reduce(holder_holds, state.items, fn {item_id, qty}, acc ->
          Map.update(acc, item_id, nil, &%{&1 | available: &1.available + qty})
        end)

      new_state = %{state | items: new_items, holds: new_holds}
      notify_observers(new_state.items)
      {:ok, new_state}
  end
end
```

## Writing your own custom hooks

The pattern generalises to any domain concept that combines state and
subscriptions:

1. Create a module (or add to an existing one) and `import Filament.Hooks`.
2. Write a function that calls one or more of `use_state`, `use_observable`,
   and `use_effect` unconditionally at its top level.
3. Return whatever tuple or value the caller needs.
4. Import and call it at the top level of `render/1` in your components.

Because hook slot identity is component-local, two components using the same
custom hook each get independent slot storage — there is no shared state
between them.

## API reference

See `Filament.Hooks` for the full `@spec` signatures of `use_state/1`,
`use_observable/2`, and `use_effect/2`.
