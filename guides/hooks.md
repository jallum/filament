# Hooks

Hooks are functions you call at the top level of `render/1` to access state,
subscribe to servers, and schedule side effects. Build application-facing,
domain-named hooks from `use_state`, `use_source`, `use_value`, and
`use_effect`. The Cart, Todo, Collaboration, and Inventory examples all
demonstrate this pattern.

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

## Writing a domain hook with use_source and use_value

Components should usually call a domain hook such as `use_cart_count(cart)`.
Inside that hook, source binding and value projection are separate:

```elixir
source = use_source(source_or_factory_fn)
value  = use_value(source, fn
  :disconnected -> default_value
  state -> project(state)
end)
```

`use_source/1` binds a reactive source for the calling fiber and returns
a stable `%Filament.Source{}` struct. HTTP renders read each source's
current value without subscribing; with `static_subscribe: false` they
don't read sources, and `use_source/1` returns `nil` until the WebSocket
connects.

`use_value/2` subscribes this fiber's hook slot to the source and
returns the projected value. The projection function receives
`:disconnected` when the source is `nil` or the mount is not yet live,
letting it return a safe default.

The argument to `use_source/1` is either:

- A `%Filament.Source{}` struct directly — typically built via the
  `cell/1` constructor that `use Filament.Observable.GenServer` injects
  (or `Filament.Source.new/2` for non-GenServer transports).
- A zero-arity factory function returning a `%Filament.Source{}` —
  called on the first connected render (and again if the underlying
  transport dies). Use this when the component owns the server's
  lifecycle.
- For a factory that closes over a changing resource ID, use
  `use_source(factory_fn, key)`. A changed key replaces the cached source
  even if the old transport remains reachable.

The struct exposes transport-specific data inside the hook. A domain hook
can return the underlying server handle so components can pass it to domain
actions without handling `Source` themselves:

```elixir
# In CartWeb.Hooks
def use_cart(session_id) do
  case use_source(fn -> Cart.Server.cell(session_id) end, session_id) do
    nil -> nil
    source -> source.data
  end
end

def use_cart_count(session_id) do
  cart = use_cart(session_id)
  source = if cart, do: Filament.Source.new(Filament.Observable.GenServer, cart)
  use_value(source, fn
    :disconnected -> 0
    state -> Cart.State.item_count(state)
  end)
end

# In components
count = use_cart_count(session_id)
on_click={fn -> Cart.Server.add_item(session_id, item) end}

# Component owns the server lifecycle — no `cell/1` override needed; the
# default constructor wraps any server reference
source = use_source(fn ->
  {:ok, pid} = Todo.Store.start_link([])
  Todo.Store.cell(pid)
end)

todos = use_value(source, fn
  :disconnected -> []
  s -> s
end)

# Multiple projections can live in separate domain hooks.
```

Passing `session_id` as a prop lets each child apply its own domain hook
without repeating the factory code or touching transport internals. The
supervised `ensure_started` lookup is idempotent, so the hooks agree on one cart.

### Projection runs client-side and can close over local state

The projection function is evaluated on the client (in the component's render
pass), not on the server. This means it can close over any local variables that
are in scope at the call site — including `use_state` values — and those
captures are always current because the projection re-runs on every render.

```elixir
{filter, set_filter} = use_state(:all)

filtered = use_value(store, fn
  :disconnected -> []
  items -> Enum.filter(items, &matches?(&1, filter))
end)
```

Whenever `filter` changes (via `set_filter`), the component re-renders and the
projection immediately applies the new filter to the latest raw state from the
server — no need to involve the server in the filtering logic.

The server applies change-or-bust on the **raw state**: it sends an update only
when `new_raw_state !== last_raw_state`. The projection is then applied
client-side each render to derive the value the component actually uses.

### handle_current/1 and handle_subscribe/2

An observable server publishes its whole state by default. Implement
`handle_current/1` to publish something else; the default
`handle_subscribe/2`, `Cell.current/2` and refreshes all read it:

```elixir
@impl Filament.Observable
def handle_current(state), do: {:ok, state.items, state}
```

Implement `handle_subscribe/2` only to track subscribers or reject them with
`{:error, reason, new_state}`; the default accepts with `handle_current/1`'s
value.

See the [Observables guide](observables.html) for the change-or-bust mechanism
and projection patterns.

## When a component renders

A component renders only when one of its inputs changes:

- its props (`!==` against the props it last rendered with),
- a `use_state` value (setting the value it already holds does nothing), or
- a value it reads with `use_value` (compared after projection).

Nothing else triggers a render. When a parent renders, each child whose
props are unchanged keeps its last output, along with its whole subtree.
When a child's state changes, only that child renders; its ancestors keep
their output.

Closures in props compare by value: two closures from the same `fn` in the
source, capturing equal values, are `===`. A parent that rebuilds
`on_pick={fn -> set_picked.(item.id) end}` on every render does not
re-render the child unless `item.id` changed. A closure capturing something
created on each render, such as `make_ref()`, makes the child render every
time.

Anything a component reads *while rendering* must come from one of these
inputs. A function prop called during render (a render prop) that reads
ETS, the process dictionary or a GenServer is still `===` after that data
changes, so the child keeps stale output. Pass the data itself, or read it
with `use_value`. Event handlers are not affected: they run when the event
fires and read current data then.

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

Any module function that calls `use_state`, `use_value`, or `use_effect`
is a custom hook. The only requirements are that it is called at the top level
of `render/1` and always calls the same hooks in the same order.

Custom hooks let you extract domain behaviour that would otherwise clutter
`render/1` and repeat across components.

### Example: use_hold (inventory example)

The inventory example (`examples/inventory/lib/inventory_web/hooks.ex`)
defines `use_hold/3` — a hook that manages quantity-based resource holds
against an `Inventory.Server`. It composes `use_value` and `use_state`
and returns a tuple of the held quantity, current item state, and
`hold`/`release` closures:

```elixir
defmodule InventoryWeb.Hooks do
  import Filament.Hooks

  def use_hold(server, item_id, opts \\ []) do
    disconnected_val = Keyword.get(opts, :disconnected, :disconnected)
    sentinel = :__hold_disconnected__

    source = use_source(Inventory.Server.cell(server))

    item =
      use_value(source, fn
        :disconnected -> sentinel
        state -> Map.get(state, item_id)
      end)

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

- **`use_source/1` + `use_value/2`** — resolves the server, then
  projects to a single item, so only updates to `item_id` trigger a re-render
  of this fiber.
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
subscriber's component unmounts or its LiveView process terminates. This means the hook itself does not
need to set up an `on_unmount` callback or `use_effect` for cleanup — the
server owns that contract:

```elixir
@impl Filament.Observable
def handle_unsubscribe(subscriber, state) do
  # subscriber is {owner_pid, fiber_id, slot_index, generation}
  {pid, fiber_id, _slot, _generation} = subscriber

  case Map.pop(state.holds, {pid, fiber_id}) do
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
2. Write a function that calls one or more of `use_state`, `use_value`,
   and `use_effect` unconditionally at its top level.
3. Return whatever tuple or value the caller needs.
4. Import and call it at the top level of `render/1` in your components.

Because hook slot identity is component-local, two components using the same
custom hook each get independent slot storage — there is no shared state
between them.

## Transport-agnostic subscription

`use_value/2` accepts any `%Filament.Source{}` regardless of which
transport backs it. The struct carries a `transport` module that
implements the `Filament.Cell` behaviour and the `data` the transport
needs (a pid, an Agent ref, a struct — whatever).

The `Filament.Observable.GenServer` transport ships with Filament;
non-GenServer transports (in-process structs, focus trackers, custom
backends) can be added without changing the hook.

```elixir
def render(_assigns) do
  source = MyApp.AgentCell.cell(agent_pid)
  # or: Filament.Source.new(MyApp.AgentCell, agent_pid)

  count = use_value(source, fn
    :disconnected -> 0
    state -> state.count
  end)

  ~F"<span>{count}</span>"
end
```

See the **[Cells guide](cells.html)** for the transport authoring
contract.

## API reference

See `Filament.Hooks` for the full `@spec` signatures of `use_state/1`,
`use_source/1`, `use_value/2`, and `use_effect/2`.
