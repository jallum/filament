# Observables

An observable is a GenServer that pushes state updates to every subscribed component
the moment something changes. Instead of polling or manually sending messages, you
call `notify_observers/1` after a mutation and all interested components re-render
automatically.

The key feature is **projections**: a subscriber can provide a function that extracts
only the slice of state it cares about. If the projection result is equal to what the
component last saw, the update is suppressed — no re-render. This is the
*change-or-bust* optimization that keeps large UIs fast.

This guide uses the Cart & Checkout example from `examples/cart`. By the end you will
understand `Observable.GenServer`, `use_observable/2` with projections, the
change-or-bust mechanism, and how to test observable components.

## The Observable.GenServer macro

`use Filament.Observable.GenServer` turns any GenServer into one that Filament
components can subscribe to. Here is the real `Cart.Server`:

```elixir
defmodule Cart.Server do
  use Filament.Observable.GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %Cart.State{}, name: name)
  end

  # Called when a new component subscribes.
  # Return {:ok, initial_value, new_state} to accept.
  @impl Filament.Observable
  def handle_subscribe(_request, _subscriber, state) do
    {:ok, state, state}
  end

  @impl GenServer
  def handle_call({:add_item, item}, _from, state) do
    new_state = Cart.State.add_item(state, item)
    notify_observers(new_state)          # push to all subscribers
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:remove_item, item_id}, _from, state) do
    new_state = Cart.State.remove_item(state, item_id)
    notify_observers(new_state)
    {:reply, :ok, new_state}
  end
end
```

What the macro injects:

- `handle_call({:filament_subscribe, ...})` — registers a subscriber and monitors
  its process. Calls your `handle_subscribe/3` callback.
- `handle_cast({:filament_unsubscribe, ...})` — removes a subscriber.
- `handle_info({:DOWN, ...})` — automatically drops subscribers whose LiveView
  process terminates.
- `notify_observers/1` — call this after every mutation. It iterates subscribers,
  applies their projections, and sends `{:filament_observable_update, ...}` only
  when the projected value changed.

The default `handle_subscribe/3` returns `{:ok, state, state}` (the current state
as the initial value). Override it to reject subscriptions or return a different
initial value.

## Subscribing from a component: use_observable/2

The `CartBadge` component subscribes with a count projection:

```elixir
defmodule CartWeb.Components.CartBadge do
  use Filament.Component

  defcomponent do
    prop(:server, :any, default: Cart.Server)

    def render(%{server: server}) do
      count_projection = fn state -> Cart.State.item_count(state) end
      count = use_observable(server, project: count_projection)

      ~F"""
      <span class="cart-badge" data-count={count}>
        {if count == 0, do: "", else: "#{count}"}
      </span>
      """
    end
  end
end
```

The `CartView` component subscribes without a projection, receiving the full state:

```elixir
def render(%{server: server}) do
  cart = use_observable(server)

  items_html =
    if cart == :disconnected do
      []
    else
      Enum.map(cart.items, fn item ->
        # ... build HTML for each item
      end)
    end
  # ...
end
```

`use_observable` has two calling forms.

**Server form** — when the server is already running (e.g. a singleton or passed as a prop):

```elixir
use_observable(server, opts \\ [])
```

- `server` — PID or registered name of the observable GenServer.
- `opts` — keyword options:
  - `:request` — passed to `handle_subscribe/3` on the server; use it to filter or
    scope the subscription (default `nil`).
  - `:project` — a one-arity function applied to each new state before delivery.
  - `:disconnected` — value returned before the WebSocket connects (default `:disconnected`).

**Subscribe form** — when the component owns the server's lifecycle:

```elixir
use_observable(subscribe: fn -> ... end, opts)
```

- `:subscribe` — zero-arity fn called once on the first WebSocket render; returns a pid
  or `{:ok, pid}`. The process is started with `start_link`, so it is linked to the
  LiveView and terminates with it automatically. Also accepts any GenServer name (pid,
  atom, `{:via, Registry, ...}`) directly when subscribing to a long-lived process.
- Same `:request`, `:project`, and `:disconnected` opts as the server form.

Returns `{pid, value}` so the pid is available for mutations. While disconnected
returns `{nil, disconnected_value}`.

```elixir
{store, todos} = use_observable(subscribe: fn -> Todo.Store.start_link([]) end, disconnected: [])
```

This eliminates the need to start the server in `mount/3` and thread it as a prop —
the LiveView can reduce to:

```elixir
defmodule TodoWeb.TodoLive do
  use Filament.LiveView
  def root_component, do: TodoWeb.Components.TodoList
end
```

On the **first render** (HTTP pre-connect), `use_observable` returns `:disconnected`
(or your `disconnected:` override) because subscribing during an HTTP render would
create zombie subscribers. Use the opt to supply a sensible default directly:

```elixir
count = use_observable(server, project: &Cart.State.item_count/1, disconnected: 0)
```

Or check the sentinel when you need branching logic:

```elixir
cart = use_observable(server)
if cart == :disconnected, do: render_loading(), else: render_cart(cart)
```

On subsequent renders (WebSocket-connected), the hook returns the projected value.

## Projections and change-or-bust

Consider two components subscribed to the same `Cart.Server`:

- `CartBadge` subscribes with `project: fn s -> Cart.State.item_count(s) end`
- `CartView` subscribes with no projection (receives the full `Cart.State`)

When a user changes the price of an item without adding or removing it:

1. `Cart.Server` calls `notify_observers(new_state)`.
2. For `CartView`: `new_state !== last_state` → update sent → re-render.
3. For `CartBadge`: `item_count(new_state) == item_count(last_state)` (count is
   unchanged) → **update suppressed** → no re-render.

Filament uses strict inequality (`!==`) for the comparison. Primitives and atoms
compare by value; maps and structs compare by identity. If your projection returns
a map you should return the same struct whenever the relevant fields haven't changed.

The projection test from `examples/cart/test/cart_test.exs` demonstrates this
directly:

```elixir
test "projection suppresses update when count is unchanged" do
  {:ok, stub} = Filament.Test.Stub.start(fn _req -> %Cart.State{} end)

  sub = %Filament.Observable.Subscriber{
    pid: self(),
    fiber_id: :badge_test_fiber,
    slot_index: 0,
    project: fn state -> Cart.State.item_count(state) end
  }

  {:ok, _initial} = Filament.Observable.subscribe(stub, nil, sub)

  # Push a state with count 0 → 1
  state1 =
    Cart.State.add_item(
      %Cart.State{},
      %Cart.Item{id: "a", name: "A", price_cents: 100, quantity: 1}
    )

  Filament.Test.Stub.push(stub, state1)
  assert_receive {:filament_observable_update, :badge_test_fiber, 0, 1}, 500

  # Push the same state again — count unchanged, no notification
  Filament.Test.Stub.push(stub, state1)
  refute_receive {:filament_observable_update, :badge_test_fiber, 0, _}, 100
end
```

## Mutations from event closures

`CartView` handles item removal via a Phoenix event (not a Filament closure), but
the pattern generalises to any mutation. The important thing is the flow:

1. User interaction triggers a call to `Cart.Server.remove_item/2`.
2. The server runs `notify_observers(new_state)`.
3. Filament sends `{:filament_observable_update, fiber_id, slot_index, projected_value}`
   to every subscribed LiveView.
4. Each subscribed component's fiber re-renders with the new value.

You do not need to do anything special in the component — just call the server and
let the observer push the update.

## Testing with rung-3

Rung-3 tests use a **real** GenServer (not a stub) and `Filament.Test.update/1` to
drain the observable update message and re-render:

```elixir
describe "CartView (rung-3, real Cart.Server)" do
  setup do
    server = start_supervised!(Cart.Server)
    {:ok, view} = mount(CartWeb.Components.CartView, %{server: server})
    %{server: server, view: view}
  end

  test "add_item updates rendered view", %{server: server, view: view} do
    Cart.Server.add_item(server, %Cart.Item{
      id: "w1",
      name: "Widget",
      price_cents: 999,
      quantity: 1
    })

    view = Filament.Test.update(view)
    assert render_text(view) =~ "Widget"
  end

  test "eventually/2 retries until cart is updated asynchronously", %{
    server: server,
    view: view
  } do
    spawn(fn ->
      Process.sleep(50)
      Cart.Server.add_item(server, %Cart.Item{
        id: "async1",
        name: "AsyncItem",
        price_cents: 100,
        quantity: 1
      })
    end)

    view_ref = make_ref()
    Process.put(view_ref, view)

    Filament.Test.eventually(
      fn ->
        current = Process.get(view_ref)
        updated = Filament.Test.update(current)
        Process.put(view_ref, updated)
        String.contains?(render_text(updated), "AsyncItem")
      end,
      timeout: 500
    )
  end
end
```

Key test helpers:

- `Filament.Test.update(view)` — drains one pending observable update message and
  re-renders the affected fiber. Returns an updated view struct.
- `Filament.Test.Stub.start(fn request -> initial_state end)` — creates an in-process
  observable stub for rung-2 isolation tests.
- `Filament.Test.Stub.push(stub, new_state)` — pushes a state update through the stub.
- `Filament.Test.eventually(fn -> bool end, timeout: ms)` — retries the predicate
  until it returns `true` or the timeout expires. Useful for asynchronous mutations.

## Observable contract

See `Filament.Observable` for the full `@callback` specifications including the
`handle_unsubscribe/2` cleanup callback.

## Next steps

- **Hooks guide** — learn how to compose hooks and build custom hooks like
  `use_hold` (see `examples/inventory/lib/inventory_web/hooks.ex` for a
  worked example of resource holds built on top of `use_observable`).
- **API reference** — see `Filament.Observable`, `Filament.Observable.GenServer`,
  and `Filament.Hooks` (`use_observable/2`) for full signatures.
