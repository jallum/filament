# Cells

A cell is the unit of reactivity in Filament — a versioned value with
subscribers and a projection-equality check. Components consume cells via
hooks (`use_source` to bind, `use_value` to read); transports —
GenServer-backed observables, in-process structs, focus trackers — provide
them. The component is unaware of which transport delivers a cell's value,
so the same component code runs against a Phoenix LiveView backend, an
out-of-process state store, or a non-web target like a TUI.

Filament splits the API surface into two related names:

- **`Filament.Cell`** — the *behaviour* a transport author implements.
  Defines the `subscribe/3`, `unsubscribe/2`, `current/2` callbacks plus
  the routing helpers that dispatch through to the transport.
- **`Filament.Source`** — the *struct* application code holds. Returned
  by `use_source/1`, accepted by `use_value/2`, passed as a child prop.

This guide is for developers who want to **author a transport** or work
with non-default cells. Most application code uses `use_value/2` and never
thinks about the cell layer; if that's you, the **[Observables
guide](observables.html)** is enough — come back here when you need to
plug something more exotic in.

## Shape

A source is a struct:

```elixir
%Filament.Source{transport: module(), data: term()}
```

`transport` implements the `Filament.Cell` behaviour. `data` is whatever
the transport needs to identify this particular cell — a GenServer pid or
registered name, an ETS table, a struct, anything. The dispatch helpers in
`Filament.Cell` route subscribe / unsubscribe / current calls through
`source.transport`.

Build sources via the per-transport `cell/1` constructor (which
`use Filament.Observable.GenServer` injects automatically), or via
`Filament.Source.new/2` directly:

```elixir
# GenServer-backed cell, via the injected constructor:
source = MyApp.CartServer.cell(MyApp.CartServer)

# Or any transport, via the explicit constructor:
source = Filament.Source.new(MyApp.AgentCell, agent_pid)

# Subscribe and read the initial value.
{:ok, value} = Filament.Cell.subscribe(source, subscriber, projection)

# Cancel a subscription. Idempotent.
:ok = Filament.Cell.unsubscribe(source, subscriber)

# Read without subscribing.
value = Filament.Cell.current(source, projection)
```

## The Cell behaviour

A transport implements three callbacks:

```elixir
@callback subscribe(transport_data, subscriber, projection) ::
            {:ok, projected_value} | :disconnected

@callback unsubscribe(transport_data, subscriber) :: :ok

@callback current(transport_data, projection) ::
            projected_value | :disconnected
```

`subscriber` is opaque to `Filament.Cell` — by convention the tuple
`{owner_pid, fiber_id, slot_index}` that Filament's hooks layer uses, but a
transport may accept any term. Two subscribes with the same identity replace
the previous projection.

`projection` is a 1-arity function the transport runs against the underlying
value. Whether the transport applies the projection at the cell or on every
render is a transport-internal decision — but every transport must support a
**change-or-bust** check: deliver an update to the subscriber only when the
projected value differs from the previously delivered one.

When a transport can't reach its underlying value (the GenServer isn't
running, the ETS table is missing) it returns `:disconnected`. The hooks
layer translates that to `projection.(:disconnected)` so components can
render a sane fallback.

## Notification protocol

When a cell's value changes, the transport sends a message to the subscriber's
process:

    {:cell_update, subscriber, projected_value}

`Filament.LiveView`'s `handle_info` for `:cell_update` updates the fiber slot
and triggers a re-render. Other backends (a TUI's `Interactive` GenServer,
say) can implement the same handler to integrate.

## Built-in transport: `Filament.Observable.GenServer`

The GenServer-backed transport ships with Filament. Any module that does
`use Filament.Observable.GenServer` becomes both a transport and a source
factory — the `Filament.Cell` behaviour callbacks are implemented at the
module level and route through `GenServer.call` / `GenServer.cast`, and a
default `cell/1` constructor (overridable) returns the right
`%Filament.Source{}`:

```elixir
defmodule Cart.Server do
  use Filament.Observable.GenServer
  # ...handlers...
end

source = Cart.Server.cell(Cart.Server)
# %Filament.Source{transport: Filament.Observable.GenServer, data: Cart.Server}
```

Servers commonly override `cell/1` to take a domain identifier and
ensure-start the underlying process:

```elixir
defmodule Cart.Server do
  use Filament.Observable.GenServer

  def cell(session_id) when is_binary(session_id) do
    Filament.Source.new(Filament.Observable.GenServer, ensure_started(session_id))
  end
end
```

## The `use_value/2` hook

`use_value(cell, projection)` is the generic cell-subscription primitive at
the component level. It accepts any cell tuple and applies the projection at
render time:

```elixir
def render(%{cart: cart_cell}) do
  count = use_value(cart_cell, fn
    :disconnected -> 0
    state -> length(state.items)
  end)

  ~F"<span class=\"badge\">{count}</span>"
end
```

The projection runs each render with the current closure, so it can safely
close over local component state (filter selections, current user, etc.).
Cell change-or-bust prevents redundant message traffic; render-level diffing
prevents redundant DOM updates.

## When to use which hook

| Hook                | When                                                              |
|---------------------|-------------------------------------------------------------------|
| `use_state/1`       | Fiber-local state. No subscription, no transport.                 |
| `use_source/1`  | Resolve a cell once for the calling fiber (factory or passthrough). |
| `use_value/2`  | Subscribe to any cell and project its current value.              |

## Authoring a transport

A minimum-viable transport implements the three callbacks against whatever
storage and notification mechanism it uses. Here's a sketch of an in-process
transport backed by an `Agent`:

```elixir
defmodule MyApp.AgentCell do
  @behaviour Filament.Cell

  use Agent

  def start_link(initial), do: Agent.start_link(fn -> %{value: initial, subs: %{}} end)

  @impl Filament.Cell
  def subscribe(agent, subscriber, projection) do
    Agent.get_and_update(agent, fn state ->
      projected = projection.(state.value)
      pid = elem(subscriber, 0)
      new_subs = Map.put(state.subs, subscriber, {pid, projection, projected})
      {{:ok, projected}, %{state | subs: new_subs}}
    end)
  end

  @impl Filament.Cell
  def unsubscribe(agent, subscriber) do
    Agent.update(agent, fn s -> %{s | subs: Map.delete(s.subs, subscriber)} end)
  end

  @impl Filament.Cell
  def current(agent, projection) do
    Agent.get(agent, fn s -> projection.(s.value) end)
  end

  def write(agent, new_value) do
    Agent.update(agent, fn state ->
      new_subs = notify_each(state.subs, new_value)
      %{state | value: new_value, subs: new_subs}
    end)
  end

  defp notify_each(subs, new_value) do
    Map.new(subs, fn {sub, {pid, projection, last}} ->
      new_projected = projection.(new_value)

      if new_projected != last do
        send(pid, {:cell_update, sub, new_projected})
      end

      {sub, {pid, projection, new_projected}}
    end)
  end
end
```

Then in a component:

```elixir
{:ok, agent} = MyApp.AgentCell.start_link(0)
source = Filament.Source.new(MyApp.AgentCell, agent)

count = use_value(source, & &1)
```

Transports may also implement the optional `reachable?/1` callback —
called by `use_source/1` to decide whether a cached source's underlying
state is still alive. The default returns `true` (assume always
reachable); the GenServer transport overrides it to check `Process.alive?`
on raw pids.

## Naming: `use_state` stays

`use_state/1` was a candidate to be renamed `use_local` for symmetry with
the source hooks (where "source" implies external; "local" implies fiber-internal).
After review the rename was rejected:

- `use_state` is the established React-family name; Filament users coming
  from React already recognise it.
- The hook is fiber-local by virtue of how Filament's render context works,
  not because of the name. Renaming wouldn't make the locality clearer.
- A rename creates churn across every component in every Filament codebase
  for no behaviour change.

The mental model stays: **`use_state` for fiber-local state, `use_source` /
`use_value` for shared / transport-backed state.**
