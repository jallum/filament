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
{:filament, "~> 0.4"}
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
    def render(_props) do
      source = use_source(MyApp.CartServer.cell(MyApp.CartServer))

      cart = use_value(source, fn :disconnected -> nil; s -> s end)
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

- `use_source/1` binds the reactive source once for the calling fiber.
  `use Filament.Observable.GenServer` injects a default `cell/1` constructor
  on every observable server — `MyApp.CartServer.cell(server_ref)` builds
  the `%Filament.Source{}` struct Filament expects.
- `use_value(source, fn :disconnected -> nil; s -> s end)` subscribes this
  component to the source and returns the current projected value. The
  function receives `:disconnected` during HTTP renders and returns a
  safe default.
- `~F"""` templates use `{expression}` interpolation and `{for ... do}` / `{end}`
  loops instead of `<%= %>` and `<% %>`.
- The component re-renders automatically when `notify_observers/1` is called on
  the server — you do not need `handle_event` to update the view.

### Source-as-prop: sharing one source across sibling components

When a parent renders multiple children that all project from the same
server, bind the source once in the parent and pass the struct as a
prop. This keeps subscriptions efficient — sibling components share the
same underlying server, each with its own projection slot:

```elixir
# Parent: bind once with use_source/1
def render(%{session_id: session_id}) do
  source = use_source(fn -> MyApp.CartServer.cell(session_id) end)

  ~F"""
  <CartBadge source={source} />
  <CartItems source={source} />
  """
end

# Child: project with use_value/2 — no redundant subscription
def render(%{source: source}) do
  count = use_value(source, fn :disconnected -> 0; s -> Cart.State.item_count(s) end)

  # Mutations reach through source.data for the underlying server reference:
  # on_click={fn -> MyApp.CartServer.add_item(source.data, item) end}
  ...
end
```

The `MyApp.CartServer.cell/1` constructor is overridable — projects with
session-keyed servers commonly override it to take the session id and
ensure-start the server (see `examples/cart/lib/cart/server.ex`).

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
def handle_info({type, _, _} = msg, socket)
    when type in [:filament_set_state, :cell_update, :cell_resubscribe] do
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

## Upgrading from older Filament releases

If you are starting fresh from the current release, skip this section —
the examples in Phases 3–6 already reflect the current API. This summary
exists for projects upgrading across Filament's pre-1.0 API shifts.

### Subscription API: tuples → `%Filament.Source{}`

Subscriptions go through `Filament.Cell`, dispatched on a struct rather
than a tagged tuple. Application code rarely sees the struct's internals
directly — `use_source/1` returns it; `use_value/2` consumes it; child
components pass it as a prop. When you need the underlying server reference
in an event handler, reach through `source.data`.

```elixir
# Before (pre-0.4 styles, in roughly historical order)
count = use_observable(CartServer, fn :disconnected -> 0; s -> s.count end)
count = use_observable({Filament.Observable.GenServer, server}, fn ... end)

# After
source = use_source(fn -> CartServer.cell(session_id) end)
count  = use_value(source, fn :disconnected -> 0; s -> s.count end)
on_click = fn -> CartServer.add_item(source.data, item) end
```

`use Filament.Observable.GenServer` now injects a default `cell/1`
constructor that builds the right struct; override it for session-keyed
ensure-started servers.

### Hook split: `use_observable` → `use_source` / `use_value`

`use_observable/1` and `use_observable/2` were two unrelated operations
(resolve vs. subscribe-and-project) sharing a name. They are now two
separately-named hooks:

- `use_source/1` — bind a reactive source once, returns
  `%Filament.Source{} | nil`.
- `use_value/2` — read a projected value from a source, subscribe to
  updates.

Older `use_projection/3` and `use_observable/2` `disconnected:` keyword
form are both gone — pass a two-clause function to `use_value/2` instead.

### `handle_subscribe/3` → `handle_subscribe/2`

The `request` argument has been removed from the `handle_subscribe`
callback. Drop the first parameter:

```elixir
# Before
def handle_subscribe(_request, _subscriber, state), do: {:ok, state, state}

# After
def handle_subscribe(_subscriber, state), do: {:ok, state, state}
```

### Subscriber identity: `%Subscriber{}` → tuple

The `Filament.Observable.Subscriber` struct is gone. `handle_unsubscribe/2`
receives the cell-subscriber tuple directly:

```elixir
# Before
def handle_unsubscribe(%Subscriber{pid: pid}, state), do: ...

# After
def handle_unsubscribe({owner_pid, _fiber_id, _slot_index}, state), do: ...
```

### Update-message names

The cell transport now sends `:cell_update` and `:cell_resubscribe`
messages (in place of the legacy `:filament_observable_updates` /
`:filament_observable_resubscribe`). `Filament.LiveView` handles them
automatically. `Filament.LiveComponent` users forwarding from the host
LiveView's `handle_info/2` should match on the new names — see the
forwarding example in Phase 5 above.

### Change-detection: raw state, client-side projection

Filament sends raw state to subscribers and each subscriber's projection
runs at render time. The component's projection can safely close over
local state — closures are fresh on every render.

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
