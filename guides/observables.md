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
understand `Observable.GenServer`, `use_value/2`, the change-or-bust mechanism,
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

- `Filament.Cell` callbacks (`subscribe/3`, `unsubscribe/2`, `current/2`,
  optional `reachable?/1`) at the module level — the GenServer becomes a
  usable transport.
- `handle_call({:filament_cell_subscribe, …})`,
  `handle_call({:filament_cell_current, …})` and
  `handle_cast({:filament_cell_unsubscribe, …})` — registers/removes
  subscribers and monitors their pids. Subscribe calls your
  `handle_subscribe/2` callback.
- `handle_info({:DOWN, …})` — automatically drops subscribers whose
  LiveView process terminates and runs your `handle_unsubscribe/2`.
- `cell/1` — default constructor returning
  `%Filament.Source{transport: Filament.Observable.GenServer, data: server_ref}`. Override
  for session-keyed lookups.
- `notify_observers/1` — call this after every mutation. For each
  subscriber, applies the subscriber's projection and delivers a
  `{:cell_update, subscriber, projected_value}` message *only* when the
  projected value differs from the previously delivered one.

The default `handle_subscribe/2`, `Filament.Cell.current/2` and refreshes
all read `handle_current/1`, which defaults to `{:ok, state, state}`. Override
it to publish a different value, and `handle_subscribe/2` only to track or
reject subscribers.

## Subscribing from a component: use_value/2

`use_value/2` takes a `%Filament.Source{}` (returned by `use_source/1`) and
a projection function. The projection receives either `:disconnected`
(before the WebSocket is established) or the raw state broadcast by the
server. The `CartBadge` component receives the source as a prop and
projects the item count:

```elixir
defmodule CartWeb.Components.CartBadge do
  use Filament.Component

  defcomponent do
    prop(:source, :any, default: nil)

    def render(%{source: source}) do
      count =
        use_value(source, fn
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

The parent component binds the source once and passes it as a prop:

```elixir
def render(%{session_id: session_id}) do
  source = use_source(fn -> Cart.Server.cell(session_id) end)

  ~F"""
  <CartBadge source={source} />
  <CartItems source={source} />
  """
end
```

`use_source/1` accepts a `%Filament.Source{}` directly or a 0-arity
factory fn that builds one (and is called on first connected render —
useful when an `ensure_started` lookup or a `start_link` is needed).
Returns `nil` during disconnected (HTTP) renders. `use_value/2` then
calls the projection with `:disconnected` so callers can return a
safe initial value.

Components that need to invoke server actions in event handlers reach
through `source.data` for the underlying transport reference:

```elixir
on_click={fn -> Cart.Server.add_item(source.data, item) end}
```

Or use a sentinel to branch on the disconnected case:

```elixir
cart = use_value(source, fn :disconnected -> nil; s -> s end)
if cart == nil, do: render_loading(), else: render_cart(cart)
```

On subsequent renders (WebSocket-connected), the hook applies the
projection to the latest raw state received from the server.

## Server lifecycle with a factory function

When the component owns the server's lifecycle, pass a factory function
to `use_source/1`. The factory must return a `%Filament.Source{}` —
typically by starting the server and wrapping the pid via the
`cell/1` constructor that `use Filament.Observable.GenServer` injects:

```elixir
source = use_source(fn ->
  {:ok, pid} = Todo.Store.start_link([])
  Todo.Store.cell(pid)
end)

todos = use_value(source, fn
  :disconnected -> []
  s -> s
end)
```

The server starts on the first render that reads sources (including HTTP
rendering by default). Resource teardown is a separate lifecycle choice; unsubscribing a
reader does not automatically stop the server.

This eliminates the need to start the server in `mount/3` and thread it as a prop —
the LiveView reduces to:

```elixir
defmodule TodoWeb.TodoLive do
  use Filament.LiveView
  def root_component, do: TodoWeb.Components.TodoList
end
```

By default the HTTP render reads each source's current value without
subscribing, and the WebSocket process subscribes on mount. With
`static_subscribe: false`, `use_source/1` returns `nil` during HTTP rendering
and `use_value/2` calls the projection with `:disconnected`.

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
  {:ok, stub} = Filament.Test.Stub.start(fn _req -> %Cart.State{} end)

  source = Filament.Source.new(Filament.Observable.GenServer, stub)
  subscriber = {self(), :badge_test_fiber, 0}

  {:ok, _initial} = Filament.Cell.subscribe(source, subscriber, &Function.identity/1)

  # Push a state with count 0 → 1
  state1 =
    Cart.State.add_item(
      %Cart.State{},
      %Cart.Item{id: "a", name: "A", price_cents: 100, quantity: 1}
    )

  Filament.Test.Stub.push(stub, state1)
  assert_receive {:cell_update, ^subscriber, ^state1}, 500

  # Push the same state again — projected value unchanged, no notification
  Filament.Test.Stub.push(stub, state1)
  refute_receive {:cell_update, _, _}, 100
end
```

## handle_subscribe return values

- `{:ok, initial_value, new_state}` — accept the subscription; `initial_value` is
  the raw state the client receives immediately (used as the seed for change-or-bust
  tracking and passed through the projection fn for the first render).
- `{:error, reason, new_state}` — reject the subscription; the component's
  `use_value` reads `:disconnected`.

`handle_subscribe/2` runs once per subscriber identity, and `handle_unsubscribe/2`
once when that subscription ends — on unsubscribe or when the owner exits. When an
owner's mailbox fills, the server stops sending it updates until it resubscribes;
that resubscribe is a refresh under the same identity, so it calls neither callback
and the resources a subscription holds survive it. The refresh reads the value from
`handle_current/1`, so a server that overrides `handle_subscribe/2`'s value must
override `handle_current/1` to match.

## Static rendering and static_subscribe

Phoenix LiveView renders each page twice: once over HTTP, then again in the
WebSocket process. `use Filament.LiveView` defaults to `static_subscribe: true`,
under which the HTTP render reads each source's current value — the server's
`handle_current/1` — so the page arrives with real data. It doesn't subscribe:
`handle_subscribe/2` isn't called and nothing outlives the request. Under HTTP
keep-alive the static render runs in the connection's process, which may live
on serving other requests, so a subscription there would linger. A presence
server therefore counts only WebSocket viewers.

With `static_subscribe: false`, the HTTP render doesn't read sources at all:
`use_source/1` returns `nil` and `use_value/2` returns its `:disconnected`
value (so you might show "Connecting…"), then the view re-renders with live data
when the WebSocket connects. Use it when reading during the HTTP render is
unwanted, for example a factory that starts a server per visitor.

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
describe "CartItems (rung-3, real Cart.Server)" do
  setup do
    server = start_supervised!(%{id: Cart.Server, start: {Cart.Server, :start_link, [[name: nil]]}})
    source = Filament.Source.new(Filament.Observable.GenServer, server)
    view = mount!(CartWeb.Components.CartItems, %{source: source})
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
  worked example of resource holds built on top of `use_value`).
- **[Cells guide](cells.html)** — the abstraction underneath observables.
  Read this if you're writing a non-GenServer transport (in-process struct,
  focus tracker, custom backend) or consuming cells handed to you by a
  backend you don't own.
- **API reference** — see `Filament.Observable`, `Filament.Observable.GenServer`,
  `Filament.Cell`, `Filament.Source`, and `Filament.Hooks` (`use_source/1`,
  `use_value/2`, `use_effect/2`) for full signatures.
