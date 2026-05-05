# Observables

An observable is a GenServer that pushes state updates to every subscribed component
the moment something changes. Instead of polling or manually sending messages, you
call `notify_observers/1` after a mutation and all interested components re-render
automatically.

The key feature is **projections**: a subscriber provides a function that extracts
only the slice of state it cares about. If the projected result equals what the
component last rendered, the update is suppressed — no re-render. This is the
*change-or-bust* optimization that keeps large UIs fast.

Projections run **client-side** (in the component fiber), not on the server. The
server sends raw state to subscribers; each subscriber's projection fn is then applied
locally. This means projection functions can safely close over local component state
without any coordination with the server.

This guide uses the Cart & Checkout example from `examples/cart`. By the end you will
understand `Observable.GenServer`, `use_observable/2`, the change-or-bust mechanism,
and how to test observable components.

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
  def handle_subscribe(_subscriber, state) do
    {:ok, state, state}
  end

  @impl GenServer
  def handle_call({:add_item, item}, _from, state) do
    new_state = Cart.State.add_item(state, item)
    notify_observers(new_state)          # push raw state to all subscribers
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
  its process. Calls your `handle_subscribe/2` callback.
- `handle_cast({:filament_unsubscribe, ...})` — removes a subscriber.
- `handle_info({:DOWN, ...})` — automatically drops subscribers whose LiveView
  process terminates.
- `notify_observers/1` — call this after every mutation. It compares the new raw
  state against the last raw state sent to each subscriber and delivers
  `{:filament_observable_updates, ...}` only when the raw state changed.

The default `handle_subscribe/2` returns `{:ok, state, state}` (the current state
as the initial value). Override it to reject subscriptions or return a different
initial value.

## Subscribing from a component: use_observable/2

`use_observable/2` takes a server reference and a projection function. The projection
function receives either `:disconnected` (before the WebSocket is established) or the
raw state broadcast by the server. The `CartBadge` component receives the server as a
prop and projects the item count:

```elixir
defmodule CartWeb.Components.CartBadge do
  use Filament.Component

  defcomponent do
    prop(:server, :any, default: nil)

    def render(%{server: server}) do
      count =
        use_observable(server, fn
          :disconnected -> 0
          s -> Cart.State.item_count(s)
        end)

      ~F"""
      <span class="cart-badge" data-count={count}>
        {if count == 0, do: "", else: "#{count}"}
      </span>
      """
    end
  end
end
```

The parent component resolves the server once and passes it as a prop:

```elixir
def render(%{session_id: session_id}) do
  server = use_observable(fn -> Cart.Server.ensure_started(session_id) end)

  ~F"""
  <CartBadge server={server} />
  <CartItems server={server} />
  """
end
```

`use_observable/1` (factory fn or pid, no projection) returns the resolved pid
(or `nil` during disconnected renders). `use_observable/2` calls the projection
function with `:disconnected` on the first HTTP render, letting it return a safe
default.

Or use a sentinel to branch on the disconnected case:

```elixir
cart = use_observable(server, fn :disconnected -> nil; s -> s end)
if cart == nil, do: render_loading(), else: render_cart(cart)
```

On subsequent renders (WebSocket-connected), the hook applies the projection to the
latest raw state received from the server.

## Server lifecycle with a factory function

When the component owns the server's lifecycle, pass a factory function directly to
`use_observable/1`:

```elixir
store = use_observable(fn -> Todo.Store.start_link([]) end)
todos = use_observable(store, fn
  :disconnected -> []
  s -> s
end)
```

The server starts when the component mounts and can stop itself in
`handle_unsubscribe/2` when the last subscriber leaves:

```elixir
@impl Filament.Observable
def handle_unsubscribe(_subscriber, state) do
  # Stop when the last subscriber (component) unmounts:
  {:stop, :normal, state}
  # Or keep running:
  # {:ok, state}
end
```

This eliminates the need to start the server in `mount/3` and thread it as a prop —
the LiveView reduces to:

```elixir
defmodule TodoWeb.TodoLive do
  use Filament.LiveView
  def root_component, do: TodoWeb.Components.TodoList
end
```

On the **first render** (HTTP pre-connect), `use_observable/1` returns `nil` because
subscribing during an HTTP render would create zombie subscribers. `use_observable/2`
calls the projection function with `:disconnected` instead.

## Projections and change-or-bust

Because projections run client-side, the server only tracks one piece of state per
subscriber: the **last raw state** it sent to that subscriber. When
`notify_observers/1` is called:

1. For each subscriber, compare `new_state !== last_raw`.
2. If equal, skip — the subscriber already has this raw state.
3. If different, deliver the raw state to the subscriber process and update
   `last_raw`.
4. The subscriber fiber applies its projection function (with the current closure)
   and updates the component only if the projected result also changed.

Consider two components subscribed to the same `Cart.Server`:

- `CartBadge` projects with `fn s -> Cart.State.item_count(s) end`
- `CartView` uses identity (receives the full `Cart.State`)

When a user changes the price of an item without adding or removing it:

1. `Cart.Server` calls `notify_observers(new_state)`.
2. Both subscribers receive the new raw state (it differs from their `last_raw`).
3. `CartView`: projected output differs → re-render.
4. `CartBadge`: `item_count(new_state) == item_count(last_state)` (count unchanged)
   → **update suppressed** → no re-render.

Filament uses strict inequality (`!==`) for both comparisons. Primitives and atoms
compare by value; maps and structs compare by identity. If your projection returns
a map you should return the same struct whenever the relevant fields haven't changed.

The projection test from `examples/cart/test/cart_test.exs` demonstrates this
directly:

```elixir
test "projection suppresses update when count is unchanged" do
  {:ok, stub} = Filament.Test.Stub.start(fn -> %Cart.State{} end)

  sub = %Filament.Observable.Subscriber{
    pid: self(),
    fiber_id: :badge_test_fiber,
    slot_index: 0
  }

  {:ok, _initial} = Filament.Observable.subscribe(stub, sub)

  # Push a state with count 0 → 1
  state1 =
    Cart.State.add_item(
      %Cart.State{},
      %Cart.Item{id: "a", name: "A", price_cents: 100, quantity: 1}
    )

  Filament.Test.Stub.push(stub, state1)
  assert_receive {:filament_observable_updates, [_]}, 500

  # Push the same state again — raw state unchanged, no notification
  Filament.Test.Stub.push(stub, state1)
  refute_receive {:filament_observable_updates, _}, 100
end
```

## handle_subscribe return values

- `{:ok, initial_value, new_state}` — accept the subscription; `initial_value` is
  the raw state the client receives immediately (used as the seed for change-or-bust
  tracking and passed through the projection fn for the first render).
- `{:error, reason, new_state}` — reject the subscription; raises
  `Filament.ObservableError` in the component.

## Mutations from event closures

`CartView` handles item removal via a Phoenix event, but the pattern generalises to
any mutation. The flow is:

1. User interaction triggers a call to `Cart.Server.remove_item/2`.
2. The server runs `notify_observers(new_state)`.
3. Filament delivers raw state updates to each subscriber whose `last_raw` differs.
4. Each subscribed component's fiber applies its projection and re-renders if the
   projected value changed.

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
- `Filament.Test.Stub.start(fn -> initial_state end)` — creates an in-process
  observable stub for rung-2 isolation tests.
- `Filament.Test.Stub.push(stub, new_state)` — pushes a raw state update through
  the stub.
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
  and `Filament.Hooks` (`use_observable/1`, `use_observable/2`) for full signatures.
