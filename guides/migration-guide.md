# Migration Guide

This guide is for teams with an existing Phoenix LiveView application who want to
adopt Filament incrementally. Filament is not all-or-nothing — you can migrate one
LiveView at a time using `Filament.LiveComponent` as an entry point, and promote to
a full Filament LiveView only when you are ready.

Prerequisite reading: [Getting Started](getting-started.html) and
[Observables](observables.html).

## Phase 1: Add Filament to your project

Add the dependency:

```elixir
# mix.exs
{:filament, "~> 0.1"}
```

Run `mix deps.get`. No other changes to your existing LiveViews are required yet.

## Phase 2: Identify your assigns

Start by reading your existing LiveView and classifying each assign by its intended
role. Here is a representative before-state:

```elixir
defmodule MyApp.CartLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, items: [], total: 0)}
  end

  def handle_event("add_item", %{"id" => id, "name" => name, "price" => price}, socket) do
    item = %{id: id, name: name, price: String.to_integer(price)}
    items = socket.assigns.items ++ [item]
    total = Enum.sum(Enum.map(items, & &1.price))
    {:noreply, assign(socket, items: items, total: total)}
  end

  def render(assigns) do
    ~H"""
    <ul>
      <%= for item <- @items do %>
        <li><%= item.name %> — <%= item.price %></li>
      <% end %>
    </ul>
    <p>Total: <%= @total %></p>
    """
  end
end
```

Classify each assign:

| Assign | Role | Target |
|--------|------|--------|
| `items`, `total` | Shared domain state | `Observable.GenServer` |
| Form input, filter | Ephemeral UI state | `use_state` in component |
| Checkout lock, seat hold | Resource claim | Custom hook (see [Hooks guide](hooks.html)) |
| Derived totals, counts | Computed from domain | Computed in server |

## Phase 3: Extract domain state into an Observable.GenServer

Move `items` and `total` out of the socket and into a GenServer:

```elixir
defmodule MyApp.CartServer do
  use Filament.Observable.GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{items: [], total: 0}, name: name)
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl Filament.Observable
  def handle_subscribe(_subscriber, state), do: {:ok, state, state}

  @impl GenServer
  def handle_call({:add_item, item}, _from, state) do
    items = state.items ++ [item]
    total = Enum.sum(Enum.map(items, & &1.price))
    new_state = %{state | items: items, total: total}
    notify_observers(new_state)
    {:reply, :ok, new_state}
  end
end
```

Start the server in your application supervisor:

```elixir
# application.ex
children = [MyApp.CartServer, ...]
```

See the [Observables guide](observables.html) for the full `Observable.GenServer`
explanation including projections and the change-or-bust mechanism.

## Phase 4: Write the Filament component

Replace the assigns-based render logic with a Filament component that subscribes
to the GenServer:

```elixir
defmodule MyApp.CartComponent do
  use Filament.Component

  defcomponent do
    prop(:server, :any, default: MyApp.CartServer)

    def render(%{server: server}) do
      cart = use_value(server, fn :disconnected -> nil; s -> s end)
      items = if cart == nil, do: [], else: cart.items
      total = if cart == nil, do: 0, else: cart.total

      ~F"""
      <div>
        <ul>
          {for item <- items do}
            <li>{item.name} — {item.price}</li>
          {end}
        </ul>
        <p>Total: {total}</p>
      </div>
      """
    end
  end
end
```

Key differences from the LiveView template:

- `use_value(server, fn :disconnected -> nil; s -> s end)` subscribes this
  component to the server and returns the current projected value. The function
  receives `:disconnected` during HTTP renders and returns a safe default.
- `~F"""` templates use `{expression}` interpolation and `{for ... do}` / `{end}`
  loops instead of `<%= %>` and `<% %>`.
- The component re-renders automatically when `notify_observers/1` is called on
  the server — you do not need `handle_event` to update the view.

### Server-as-prop: sharing one server across sibling components

When a parent renders multiple children that all project from the same server, resolve
the server once in the parent and pass the pid as a prop. This keeps subscriptions
efficient — each `{parent_pid, request}` pair shares a single subscriber entry on the
server regardless of how many projections it has:

```elixir
# Parent: resolve once with use_source/1
def render(%{session_id: session_id}) do
  server = use_source(fn -> MyApp.CartServer.start_link(session_id) end)

  ~F"""
  <CartBadge server={server} />
  <CartItems server={server} />
  """
end

# Child: project with use_value/2 — no redundant subscription
def render(%{server: server}) do
  count = use_value(server, fn :disconnected -> 0; s -> Cart.State.item_count(s) end)
  ...
end
```

## Phase 5: Embed in the existing LiveView (incremental adoption)

You do not have to rewrite the whole LiveView at once. Embed the Filament component
using `Filament.LiveComponent`:

```heex
<%!-- In your existing LiveView template: --%>
<.live_component
  module={Filament.LiveComponent}
  id="cart"
  component={MyApp.CartComponent}
/>
```

Because `Filament.LiveComponent` runs inside the parent LiveView process, observable
update messages must be forwarded from the parent's `handle_info/2`:

```elixir
# In MyApp.CartLive:
def handle_info({type, _} = msg, socket)
    when type in [:filament_set_state, :filament_observable_updates,
                  :filament_observable_resubscribe] do
  Phoenix.LiveView.send_update(Filament.LiveComponent, id: "cart", filament_msg: msg)
  {:noreply, socket}
end
```

This is a Phase 1 limitation described in `Filament.LiveComponent`. You only need
this forwarding while the component is hosted inside a regular LiveView.

For components that use only `use_state` (no `use_value`), no forwarding is
needed because state updates are handled internally within the same process.

## Phase 6: Full migration (optional)

Once the entire LiveView template is replaced with Filament components, switch from
the incremental adapter to `Filament.LiveView`:

```elixir
defmodule MyApp.CartLive do
  use Filament.LiveView
  def root_component, do: MyApp.CartComponent
end
```

This eliminates the need for the `handle_info` forwarding pattern — `Filament.LiveView`
handles all internal messages automatically. See the [Getting Started guide](getting-started.html)
for the full `Filament.LiveView` explanation.

## Phase 7: Add resource holds (if needed)

If your application has checkout flows, pessimistic locks, or reservation UX, holds
are not part of Filament core — but they are straightforward to build as a custom
hook on top of `use_value`. See
`examples/inventory/lib/inventory_web/hooks.ex` for a complete `use_hold/3`
implementation that acquires and releases quantity-based holds, with automatic
release when the LiveView disconnects via `handle_unsubscribe/2` on the server.
The [Hooks guide](hooks.html) covers composing and writing custom hooks.

## Observable API breaking changes

This section documents the breaking changes to the Observable/subscription API
introduced after the initial 0.1 release. If you are starting fresh from the
current release you can skip this section — the examples in Phases 3–6 above
already reflect the new API.

### `use_projection/3` removed — use `use_value/2` instead

`use_projection/3` no longer exists. Replace every call with `use_value/2`,
passing a two-clause function that handles the `:disconnected` case and projects
the live state. The function runs client-side at render time and can close over
local component assigns.

```elixir
# Before
server = use_source(CartServer)
count = use_projection(server, fn state -> Cart.State.item_count(state) end, disconnected: 0)

# After
count = use_value(CartServer, fn
  :disconnected -> 0
  state -> Cart.State.item_count(state)
end)
```

The old `disconnected:` keyword option form of `use_value/2` is also gone —
use the function-argument form shown above for all cases.

### `handle_subscribe/3` → `handle_subscribe/2`

The `request` argument has been removed from the `handle_subscribe` callback.
Drop the first parameter:

```elixir
# Before
def handle_subscribe(_request, _subscriber, state), do: {:ok, state, state}

# After
def handle_subscribe(_subscriber, state), do: {:ok, state, state}
```

### `Observable.subscribe/3` → `Observable.subscribe/2`

The `request` argument has been dropped from `Observable.subscribe/3`. If you
call this function directly (e.g. in tests or low-level integration code), remove
the second positional argument:

```elixir
# Before
Observable.subscribe(server, nil, subscriber)

# After
Observable.subscribe(server, subscriber)
```

`Observable.remove_projection/5` is now `Observable.remove_projection/4` for the
same reason — the `request` argument is gone.

### `Subscriber` struct fields

`Subscriber.request` and `Subscriber.projections` have been removed. The
replacement for tracking active projections is `proj_keys`, a map of
`{fiber_id, slot_index}` tuples to `true`:

```elixir
# Before
%Subscriber{pid: self(), request: nil, projections: %{{"root", 0} => {& &1, :unset}}}

# After
%Subscriber{pid: self(), proj_keys: %{{"root", 0} => true}}
```

### `{:subscribed, ...}` slot shape

The four-element `{:subscribed, server, request, projected_value}` tuple is gone.
If you pattern-match on this shape anywhere, remove the `request` element.

### Change-detection: raw state, client-side projection

Previously the server compared projected values to decide whether to push an
update. The server now sends raw state to all subscribers and each subscriber
compares the raw value (`new_raw !== last_raw`) independently. Projection
functions are applied at render time on the client side. The practical effect:

- The projection function passed to `use_value/2` can safely close over
  component-local state without needing the server to know about it.
- All subscribers to the same server share one raw-state broadcast; there is no
  per-projection diffing on the server.

## Codemods (where automatable)

Several transformations follow a mechanical pattern that could be automated:

- `assign(socket, key: value)` in `handle_event` → `use_state` in the component
- `socket.assigns.key` in render → bind the variable in `render/1` pattern match
- `socket.assigns.key` in templates → `{variable}` or `{@key}` in `~F` templates
- `handle_event("name", params, socket)` → `on_*` closure in the template; state
  updates via captured `use_state` setters, side effects via captured server refs

These are not shipped as codemod tools in this release. The patterns are regular
enough that a Sourceror-based transform could automate most of them. Community
contributions are welcome — the Getting Started guide provides the target syntax.

## What does NOT need to change

- Routing, controllers, and non-LiveView code: untouched.
- Existing LiveViews that are not being migrated: leave them alone.
- Phoenix layout files and `root.html.heex`: no changes required.
- Test infrastructure: Filament's rung-2 test API is additive; you keep your
  existing `Phoenix.LiveViewTest` tests for non-Filament LiveViews.
