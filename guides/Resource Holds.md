# Resource Holds

A resource hold is a server-side claim tied to the requesting process's lifetime.
When the process terminates — whether cleanly (user closes tab) or via crash — the
hold is released automatically through BEAM's `:DOWN` monitoring. No TTL timers, no
background jobs, no orphaned reservations.

This is the right abstraction for checkout flows, pessimistic locks, seat
reservations, or any scenario where "the user is looking at it" should map directly
to "the system holds it" for exactly as long as the user's connection lives.

This guide uses the Inventory example from `examples/inventory`. By the end you will
understand `Hold.GenServer`, `use_hold/3`, the `:DOWN` lifecycle, out-of-stock UX,
and the architectural constraint for combining holds with observables.

## The Hold.GenServer macro

`use Filament.Hold.GenServer` turns any GenServer into one that can grant resource
holds to Filament components. Here is the real `Inventory.Server`:

```elixir
defmodule Inventory.Server do
  use Filament.Hold.GenServer

  def start_link(opts \\ []) do
    initial_items = Keyword.get(opts, :items, [])
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, initial_items, name: name)
  end

  @impl GenServer
  def init(items) do
    state = Map.new(items, fn item -> {item.id, item} end)
    {:ok, state}
  end

  # Called when a component calls use_hold(server, item_id).
  # Return {:ok, token, new_state} to grant or {:error, reason, new_state} to deny.
  @impl Filament.Hold
  def handle_acquire(item_id, _holder_pid, state) do
    case Map.get(state, item_id) do
      nil                -> {:error, :not_found, state}
      %{available: 0}    -> {:error, :insufficient, state}
      item ->
        token = {item_id, make_ref()}
        new_item = %{item | available: item.available - 1}
        {:ok, token, Map.put(state, item_id, new_item)}
    end
  end

  # Called when the holder process dies (:DOWN) or the fiber unmounts.
  # token was returned by handle_acquire/3.
  @impl Filament.Hold
  def handle_release({item_id, _ref}, _holder_pid, state) do
    case Map.get(state, item_id) do
      nil  -> {:ok, state}
      item ->
        new_item = %{item | available: item.available + 1}
        {:ok, Map.put(state, item_id, new_item)}
    end
  end
end
```

What the macro injects:

- `handle_call({:filament_acquire, request, holder})` — acquires a hold and monitors
  the holder process. Calls your `handle_acquire/3`.
- `handle_cast({:filament_release, holder})` — explicit release on fiber unmount.
  Calls your `handle_release/3`.
- `handle_info({:DOWN, ref, :process, ...})` — fires automatically when the holder
  process dies; calls `handle_release/3` with the saved token.

The `token` is opaque: Filament stores it in the fiber's hook slot and passes it back
to `handle_release/3` — you choose its shape in `handle_acquire/3`.

## Acquiring a hold from a component: use_hold/3

The `CheckoutLineItem` component acquires a hold and renders based on the result:

```elixir
defmodule InventoryWeb.Components.CheckoutLineItem do
  use Filament.Component

  alias Filament.Hooks

  defcomponent do
    prop(:item_id, :string, required: true)
    prop(:server, :any, default: Inventory.Server)

    def render(%{item_id: item_id, server: server}) do
      {hold_acquired, _token} =
        try do
          token = Hooks.use_hold(server, item_id)
          {true, token}
        rescue
          Filament.HoldError ->
            {false, nil}
        end

      item = Inventory.Server.get_item(server, item_id)

      if hold_acquired do
        ~F"""
        <div>
          <span>{item.name}</span>
          <span>Available: {item.available}</span>
          <span>Hold acquired</span>
        </div>
        """
      else
        ~F"""
        <div>
          <span>{item.name}</span>
          <span>Available: {item.available}</span>
          <span>Out of Stock</span>
        </div>
        """
      end
    end
  end
end
```

`use_hold(server, request, opts \\ [])` signature:

- `server` — PID or registered name of the `Hold.GenServer`.
- `request` — passed as the first argument to `handle_acquire/3`. Use it to
  identify what resource to hold (item ID, seat number, document ID, etc.).
- Returns the opaque token from `handle_acquire/3` when the hold is granted.
- Raises `Filament.HoldError` when the server denies the request — rescue it to
  render the fallback UI (out-of-stock, locked, etc.).
- On the first render (HTTP pre-connect), `use_hold` returns `:uninitialized`; the
  hold is actually acquired on the WebSocket-connected render.

## The :DOWN lifecycle in practice

Here is the complete lifecycle for a checkout flow:

1. User opens the checkout page → `CheckoutLineItem` mounts → `use_hold` calls
   `Inventory.Server.handle_acquire/3` → inventory decremented by one.
2. User closes their browser tab → Phoenix LiveView process receives a disconnect
   signal and terminates.
3. BEAM sends `{:DOWN, ref, :process, pid, reason}` to `Inventory.Server`.
4. The server's injected `handle_info/2` fires → calls `handle_release/3` with the
   saved token → inventory restored.

No TTL timer, no cleanup job, no manual message required.

The process-death test from `test/filament/examples/inventory_test.exs` proves this
works:

```elixir
test "process death releases hold automatically", %{server: server} do
  item = Inventory.Server.get_item(server, "item-a")
  assert item.available == 2

  # We hold one unit
  {:ok, _our_token} = Filament.Hold.acquire(server, "item-a", self())
  assert Inventory.Server.get_item(server, "item-a").available == 1

  # Spawn a second holder
  parent = self()
  holder = spawn(fn ->
    {:ok, _token} = Filament.Hold.acquire(server, "item-a", self())
    send(parent, :acquired)
    receive do: (:die -> :ok)
  end)

  assert_receive :acquired, 500

  # Kill the holder — :DOWN fires on Inventory.Server
  Process.exit(holder, :kill)
  Process.sleep(50)    # :DOWN is async; give the server a moment

  # Available restored to 1 (we still hold ours)
  assert Inventory.Server.get_item(server, "item-a").available == 1
end
```

The `Process.sleep(50)` is necessary because `:DOWN` is delivered asynchronously —
the test process would otherwise query the server before the `:DOWN` message is
processed.

## Out-of-stock UX

When `handle_acquire/3` returns `{:error, :insufficient, state}`, `use_hold` raises
`Filament.HoldError`. Rescue it to render an appropriate fallback:

```elixir
{hold_acquired, _token} =
  try do
    token = Hooks.use_hold(server, item_id)
    {true, token}
  rescue
    Filament.HoldError -> {false, nil}
  end
```

The hold is **not** retried automatically. Once a fiber mounts and the hold attempt
is denied, the fiber stays in the error state unless the component is unmounted and
remounted. If you want the UI to recover when stock becomes available, combine
`use_hold` with `use_observable`: subscribe to inventory changes with `use_observable`
and re-attempt the hold when the observable signals that availability increased.

The rung-2 competition test from inventory_test.exs shows two components racing for
the last unit:

```elixir
test "two components competing for last unit" do
  items = [%Inventory.Item{id: "last", name: "LastUnit", available: 1}]
  server = start_supervised!({ Inventory.Server, [items: items] })

  # view1 mounts first and acquires the only unit
  {:ok, view1} = mount(InventoryWeb.Components.CheckoutLineItem,
    %{server: server, item_id: "last"})

  parent = self()
  spawn(fn ->
    # view2 in a separate process sees the unit already held
    {:ok, view2} = mount(InventoryWeb.Components.CheckoutLineItem,
      %{server: server, item_id: "last"})

    result = String.contains?(render_text(view2), "Out of Stock")
    send(parent, {:view2_result, result})
  end)

  assert_receive {:view2_result, true}, 1000
  refute render_text(view1) =~ "Out of Stock"
end
```

## Advanced aside: combining holds with observables

> #### :DOWN conflict warning {: .warning}
>
> Do **not** use both `use Filament.Hold.GenServer` and
> `use Filament.Observable.GenServer` in the same module. Both macros inject
> `handle_info/2` for `{:DOWN, ref, :process, pid, reason}` and the compiler will
> raise a duplicate clause error.

If you need a server that both notifies subscribers **and** manages holds (for
example, a document server with pessimistic locking and presence tracking), use only
`use Filament.Observable.GenServer` and implement hold management manually in the
server state.

`examples/collaboration/lib/collaboration/document_server.ex` shows exactly this
pattern:

```elixir
defmodule Collaboration.DocumentServer do
  @moduledoc """
  Document Server implementing both Observable and hold management.

  DESIGN NOTE: This server combines Filament.Observable.GenServer with custom
  hold management for document locks. The Observable macro handles subscriber
  tracking and presence counting, while we manually manage the document lock
  state. When subscribers holding the lock disconnect, the :DOWN handler releases
  the lock automatically.
  """
  use Filament.Observable.GenServer

  defstruct [:doc_id, content: "", lock_holder: nil, presence: 0]
```

The server stores `lock_holder: pid() | nil` in its own state. The existing
`handle_unsubscribe/2` callback (injected by `Observable.GenServer`) detects when
the lock holder disconnects and releases the lock:

```elixir
@impl Filament.Observable
def handle_unsubscribe(subscriber, state) do
  new_state =
    state
    |> maybe_release_lock(subscriber.pid)
    |> decrement_presence()

  notify_observers(observable_view(new_state))
  {:ok, new_state}
end

defp maybe_release_lock(state, pid) do
  if state.lock_holder == pid, do: %{state | lock_holder: nil}, else: state
end
```

The key insight: `handle_unsubscribe/2` already fires when a subscriber process dies
(via `:DOWN`). By checking whether the dying subscriber was the lock holder, you get
automatic lock release without a second `:DOWN` clause.

## Next steps

- **Migration guide** — learn how to extract LiveView assigns into `Observable.GenServer`
  with phased codemods.
- **API reference** — see `Filament.Hold`, `Filament.Hold.GenServer`, and
  `Filament.Hooks` (`use_hold/3`) for full signatures.
- **Observables guide** — if you need both subscriptions and holds in one server,
  start there.
