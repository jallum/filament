# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A target-independent vnode renderer and `Filament.Core` event dispatcher,
  with capture/bubble phases and `stop_propagation/1`. Phoenix LiveView and
  LiveComponent convert resolved vnodes through `Filament.Web`.
- `%Filament.Source{}` and the `Filament.Cell` transport behaviour for reactive
  values beyond GenServers.
- `use_source/1` to bind a source and `use_value/2` to subscribe and project
  its value.
- `Filament.LiveView` unmounts its tree in `terminate/2`, running effect
  cleanups when the client disconnects. `Filament.Test.unmount/1` does the
  same for a test view.
- `use_value/2` reconnects. It monitors the process behind a source, through
  the optional `Filament.Cell.whereis/1` callback, and subscribes again when
  that process exits, so a server restarted under a name or via-tuple
  reaches its readers without a reload. A subscribe that can't reach its
  source retries with backoff (100 ms doubling to 5 s) until it connects or
  the reader unmounts. Requires OTP 27 or later, for tagged monitors.

### Changed

- **Breaking:** `use_observable` now goes through `Filament.Cell`. The hook
  takes a cell tuple `{transport, data}` (or a 0-arity factory returning
  one) instead of a raw GenServer reference. For an observable GenServer
  the migration is mechanical — wrap the server pid in a tuple:

  ```elixir
  # Before
  count = use_observable(server, fn :disconnected -> 0; s -> s.count end)

  # After
  cell  = {Filament.Observable.GenServer, server}
  count = use_observable(cell,   fn :disconnected -> 0; s -> s.count end)
  ```

  The factory form (`use_observable/1`) returns the cell, which can then
  be passed as a prop to children that subscribe with their own
  projections.

- `Filament.Observable.GenServer.handle_unsubscribe/2` is now invoked
  with the cell-subscriber tuple `{owner_pid, fiber_id, slot_index}`
  rather than the old `%Subscriber{}` struct. Servers that read
  `subscriber.pid` need to destructure the tuple instead.

- **Breaking:** components render only when their inputs change. A parent's
  render reuses each child whose props are unchanged (`===`), with its whole
  subtree; a child's state or `use_value` update renders that child alone,
  not its ancestors; and setting state to the value it holds renders
  nothing. Closures in props compare equal when they come from the same
  `fn` and capture equal values. A component that read anything else during
  render (ETS, the process dictionary, a GenServer call, a render-prop
  function reading such data) and relied on an unrelated render to refresh
  must take that data as a prop, state or `use_value` instead. This replaces
  0.5.x's compiler-generated `memo_at` child memoization.
- **Breaking:** `use_state` setters send
  `{:filament_set_state, fiber_id, slot_index, token, value}`. The token
  identifies the component instance, so a setter kept from an unmounted
  component no longer writes into one remounted at the same position. Hosts
  forwarding messages to `Filament.LiveComponent` should match on the first
  element rather than the tuple size:

  ```elixir
  def handle_info(msg, socket)
      when elem(msg, 0) in [:filament_set_state, :cell_update, :cell_updates, :cell_resubscribe] do
    Phoenix.LiveView.send_update(Filament.LiveComponent, id: "cart", filament_msg: msg)
    {:noreply, socket}
  end
  ```
- **Breaking:** components rendered by the same parent component with the
  same module and `:key` raise `ArgumentError`
  instead of sharing one fiber and its state.
- A repeat subscribe under the same identity, as after a saturation notice, is
  a refresh: it calls neither `handle_subscribe/2` nor `handle_unsubscribe/2`,
  so held resources survive, and it replies with `handle_current/1`. The
  default `handle_subscribe/2` accepts with `handle_current/1`'s value, so a
  server publishing something other than its whole state overrides
  `handle_current/1` alone.
- `Filament.Observable.GenServer` wraps the module's own `handle_info/2`
  instead of adding clauses in front of it: the module still receives its own
  `:DOWN` messages, and a module without `handle_info/2` logs unexpected
  messages as `GenServer` does.
- Effects run in declaration order, a parent's before its children's.
- `Filament.Observable.GenServer` receives unsubscribes as a cast, so
  unmounting doesn't wait on a busy server. A later call from the same owner
  still sees the unsubscribe applied.
- The static HTTP render reads each source's current value
  (`handle_current/1`) instead of subscribing. Under HTTP keep-alive the static
  render runs in the connection's process, so its subscriptions outlived the
  request; presence servers also counted the static render as a viewer.
  `static_subscribe: false` still skips reading sources during that render.

### Fixed

- `handle_subscribe/2` returning `{:error, reason, state}` reads as
  `:disconnected`, as documented, instead of crashing the server.
- Subscribers with identities other than the hook tuple receive updates at
  the subscribing process.
- A subscribe that times out removes the subscription the server may still
  make.
- `on_click={nil}` and other `on_*` attributes given `nil` or `false` omit the
  attribute, as HEEx omits `phx-click={nil}`, instead of raising.
- `:if` beside `:for` on components and slot entries compiles and filters
  each iteration.
- Attribute names, event references, and `data`/`aria`/`phx` keyword values
  are escaped as HEEx escapes them, and literal attribute values render as
  written.
- Send saturation recovery notices once per episode, resuming delivery from fresh state after resubscription.
- Removed descendants run cleanup exactly once; keyed descendants retain
  state, and stale messages from replaced subscriptions are ignored.
- LiveComponent handles batched Cell updates while preserving its root output.
- A cell server no longer crashes notifying a subscriber on another node.
- A `Filament.LiveView` receiving a message it doesn't handle logs it and
  continues, as Phoenix does, instead of crashing. A view with its own
  `handle_info/2` ends with `def handle_info(msg, socket), do: super(msg, socket)`.
- `Filament.LiveComponent` remounts when its `component` assign changes,
  instead of rendering the new component with the old one's tree.
- HTML loop `:key` expressions are evaluated in generator scope, avoiding
  unused-variable warnings for bindings used only by the key.
- The 0.5.6 observable fixes apply on the cell transport: the injected
  cell subscribe, current-value, unsubscribe and `:DOWN` handlers keep
  the server's `timeout/1`; a cell subscriber that has exited is skipped
  quietly until its `:DOWN`; and `use_value` skips the render when every
  projected value is unchanged (`===`), keeping the fresh raw value for
  the next render.

### Removed

- `Filament.Observable.Subscriber`, `Filament.Observable.subscribe/2`,
  `remove_projection/4`, and the parallel Subscriber-keyed subscription path.
- Legacy `:filament_observable_updates` / `:filament_observable_resubscribe`
  messages. Transports use `:cell_update`, `:cell_updates`, and
  `:cell_resubscribe`; host LiveViews forwarding to LiveComponent must include
  all three forms.
- `Filament.RenderContext.observable_stubs` and `session_token`. Tests pass
  sources built against stub pids directly.
- Compiler-generated `memo_at/3` calls. The vnode compiler no longer depends
  on Phoenix's lazy comprehension functions or their hoisting passes.
- `Filament.ObservableError`, which nothing raised.
- `Reconciler.unmount/2` ignores its options; cleanup no longer needs the owner.
- `Filament.Test.mount/3`'s `:stub` option, which no longer did anything.
  Pass a source built on a `Filament.Test.Stub` pid as a prop instead.

## [0.5.6] - 2026-10-08

### Added

- An observable server can keep a GenServer timeout. `Filament.Observable`
  has a new optional `timeout/1` callback, `:infinity` by default.
  Filament's own handlers (subscribe, projection removal, a subscriber's
  `:DOWN`) now return the timeout it gives. Before this, any of those
  messages arriving while a server waited on `{:noreply, state, ms}`
  cancelled the timeout, so a held change could wait indefinitely (#32).

  ```elixir
  defmodule Batcher do
    use Filament.Observable.GenServer

    @impl Filament.Observable
    def timeout(%{pending: []}), do: :infinity
    def timeout(_state), do: 50
  end
  ```

- Inline markup inside a module component tag is passed to the component
  as its `children` prop, rendered with `{children}` like any other prop.
  Before this, the markup had to be passed through an assigns variable
  (#35).

  ```elixir
  ~F"<Page><h1>{title}</h1></Page>"

  # in Page:
  def render(%{children: children}), do: ~F"<main>{children}</main>"
  ```

### Fixed

- A component using `use_observable/2` with a projection no longer
  re-renders when every projected value is unchanged (`===`) after a
  server update. The latest raw state is still retained, and the
  projection closure is refreshed on every render, so a later local change
  (such as a filter) projects against fresh data (#34).
- An observable server no longer logs a "mailbox saturated (depth=dead)"
  warning or attempts a resubscribe when notifying a subscriber that has
  already exited; it is skipped quietly until its `:DOWN` cleanup removes
  it (#33).
- Components and event handlers inside `:for` / `{for}` loops now stay
  behind their enclosing `{if}` / `{case}` branches. Before this, a
  component under a false `{if}` in a loop could still render, and a
  handler or component using a variable bound by a `{case}` pattern could
  lose that binding (#36).

## [0.5.5] - 2026-10-07

### Added

- `~F` templates now support `{cond do}` blocks. Before this, a `cond`
  in a template failed to compile. Each clause can render markup or a
  short inline expression, and clauses can contain other blocks (`case`,
  `cond`, `for`). Only the first matching clause is evaluated, and if no
  clause matches, `CondClauseError` is raised as in plain Elixir. A `cond`
  with no clauses, or a clause outside a block, raises a clear parse
  error (#30).

  ```elixir
  ~F"""
  {cond do}
    {count == 0 ->}<button on_click={fn -> set_count.(1) end}>start</button>
    {true ->}<button on_click={fn -> set_count.(0) end}>finish</button>
  {end}
  """

  ~F|<p>{cond do}{n > 1 -> "big"}{true -> "small"}{end}</p>|
  ```

### Fixed

- Clicking a button rendered by a helper function's `~F` template now
  always runs that button's own handler. Before this, a helper template
  (or one helper called more than once) could get the same event refs as
  the template around it or as a `:for` loop's cached handlers, so a
  click could run another button's handler. The same overlap could make
  helpers share memoized results. This also holds when a conditional
  helper is removed and the buttons after it shift position (#29).

## [0.5.4] - 2026-10-01

### Fixed

- Clicking a keyed child whose key contains a colon (for example
  `:key={"type: fmj"}`) no longer crashes the LiveView. Event refs are
  sent to the client as `<fiber id>:<handler index>`, and a keyed child's
  fiber id includes its key. Filament used to split the ref at the first
  colon, so a colon inside the key broke it. It now splits at the last
  colon, which is always the separator because the handler index is only
  digits. A malformed ref is now ignored instead of crashing the LiveView.
  `Filament.Test` reads refs the same way (#26).

## [0.5.3] - 2026-10-01

### Fixed

- A subscriber whose mailbox overflows now gets one recovery notice per
  overflow, not one per state change. Before this, every update during an
  overflow sent the already-overloaded process another notice. The
  subscriber now gets no updates until it resubscribes, and resubscribing
  (including a session handoff to a replacement process) always returns the
  current state, never the last value sent before the overflow (#24).

## [0.5.2] - 2026-09-28

### Added

- `~F` templates now support `{case ... do}` blocks. Before this, `~F`
  treated a `case` header and its clauses as plain expressions, so
  templates that picked a branch by pattern failed to compile. Clauses can
  use tuple patterns, guards and a catch-all, and can contain other blocks.
  A `case` with no clauses raises a clear parse error (#14).

  ```elixir
  ~F"""
  {case primary do}
    {{:scan, label} ->}
      <button>{label}</button>
    {{:review, count} when count > 0 ->}
      <a href="/reviews">{count} reviews</a>
    {_ ->}
      <span>unknown</span>
  {end}
  """
  ```

### Fixed

- Nested `{for}` blocks now compile when the inner loop's variables
  (including destructured ones like `{tag, label}`) are used in inner
  markup, event handlers, or child components. An inner variable with the
  same name as an outer value no longer hides changes to the outer value
  (#18).

## [0.5.1] - 2026-09-27

### Fixed

- Fixed `undefined variable "binary"` compilation errors when an
  interpolated `class` and a function-valued attribute appear inside
  a `:for` subtree, including on different elements (#9).

## [0.5.0] - 2026-09-18

### Changed

- **Breaking:** raised the minimum `phoenix_live_view` requirement from
  `~> 1.0` to `~> 1.2`. Filament no longer supports `phoenix_live_view`
  1.1.x; upgrade `phoenix_live_view` to `~> 1.2` (1.2.12+ recommended)
  before upgrading to this release.
- **Breaking:** raised the minimum Elixir requirement from `~> 1.17` to
  `~> 1.18`. CI now tests against Elixir 1.18 (floor) through 1.20 (latest).

### Fixed

- Compatibility with `phoenix_live_view` 1.2.x, which made two internal,
  `@moduledoc false` contract changes with no deprecation path:

  - `Phoenix.LiveView.Tokenizer` and `Phoenix.LiveView.Tokenizer.ParseError`
    were renamed to `Phoenix.LiveView.TagEngine.Tokenizer` and
    `Phoenix.LiveView.TagEngine.Tokenizer.ParseError`. Filament's aliases
    now point at the new module names.
  - `Phoenix.Component.MacroComponent.build_ast/2` (used to implement
    `:type={...}` macro components, e.g. `Phoenix.LiveView.ColocatedHook`)
    no longer accepts a raw, unfinalized token stream and hunts for its own
    closing tag; it now only accepts an already-finalized `{:block, ...}` /
    `{:self_close, ...}` tree node and returns `{:ok, ast}` instead of
    `{:ok, ast, rest}`. Filament's `~F` compiler now assembles that
    finalized node itself (mirroring how it already pairs open/close tags
    for ordinary tags) before calling `build_ast/2`, and computes the
    remaining token stream on its own. The now-removed
    `MacroComponent.encode_binary_attribute/2` helper (used when rendering
    a macro component's transformed attributes back to HTML) is also
    inlined locally.

## [0.4.1] - 2026-05-09

### Added

- `Filament.Experimental.Hooks.use_event_ref/1` now supports 2-arity handlers
  that receive a `push/2` fn as their second argument, paired with a new
  `window.filament.handleEvent` JS helper. Together they let a component push
  events back to the specific JS hook instance that called in — scoped
  automatically via the wire ref, so multiple hook instances on the same page
  never cross:

  ```elixir
  ref = use_event_ref(fn payload, push ->
    push.("progress", %{step: 1})
    push.("done", payload)
  end)

  ~F"""
  <div phx-hook="MyHook" data-ref={ref} />
  """
  ```

  ```javascript
  // hook
  const handleEvent = window.filament.handleEvent(this);
  handleEvent("progress", ({step}) => /* ... */);
  handleEvent("done", (data) => /* ... */);
  ```

### Fixed

- Keyed comprehensions (`:for` + `:key` on a component tag) wrapping child
  components or event handlers no longer raise `"hook called outside a render
  pass"` after a re-render. The `~F` compiler's comprehension hoister matched
  only non-keyed entry tuples (first element `nil`), so `component_keyed`
  calls stayed inside keyed entry fn bodies and crashed when LiveView's diff
  engine re-invoked them outside the Filament render context. The hoister
  now handles both keyed and non-keyed entry tuples.

## [0.4.0] - 2026-05-08

### Added

- `:key` attribute on component tags inside `:for` loops in `~F` templates. Components are now
  identified by their key rather than their position in the list, giving stable fiber identity
  across reorders without any manual VNode construction:

  ```elixir
  # before — manual {:keyed_list, ...} VNode
  def render(%{items: items}) do
    keyed = Enum.map(items, fn item ->
      {item.id, {:component, MyItem, %{item: item}, item.id}}
    end)
    {:keyed_list, keyed}
  end

  # after — declarative :key attribute
  def render(%{items: items}) do
    ~F"""
    <MyItem :for={item <- items} :key={item.id} item={item} />
    """
  end
  ```

- `Filament.Experimental.Hooks.use_event_ref/1` — registers an event handler and returns a
  stable wire ref string (e.g., `"filament:root.MyComponent[0]:0"`) that a JS hook can pass
  directly to `pushEvent`, routing the event to the specific fiber without session IDs or
  process-dictionary workarounds:

  ```elixir
  import Filament.Experimental.Hooks

  def render(props) do
    submit_ref = use_event_ref(fn %{"text" => t} -> ... end)
    ~F"""
    <textarea phx-hook="MyHook" data-ref={submit_ref} />
    """
  end
  ```

  Opt in with `import Filament.Experimental.Hooks`. The API is experimental and may change.

### Removed

- `{:keyed_list, ...}` VNode type and all related renderer/validation logic. Use `:for` + `:key`
  on component tags in `~F` templates instead (see above).

## [0.3.0] - 2026-05-07

### Added

- `on_key` attribute for zero-config keyboard event handling. Add it to any
  element to bind a window-level keydown handler; the handler receives the key
  string and a `%Filament.KeyModifiers{}` struct with `ctrl`, `shift`, `alt`,
  and `meta` boolean fields — no `phx-key`, no custom JS hook required:

  ```elixir
  ~F"""
  <div on_key={fn "Escape", _ -> close() end}>
    …
  </div>
  """
  ```

  Pattern match on the key string to filter; use `_` to ignore modifiers you
  don't care about.

- Bang variants for all `Filament.Test` helpers: `mount!/2`, `click!/2`,
  `submit!/3`, `change!/3`, `blur!/2`, `key_down!/2`, `key_down!/3`. Each
  unwraps `{:ok, view}` and raises on error, enabling pipeline-style test
  composition:

  ```elixir
  mount!(Counter, %{initial: 0})
  |> click!("button")
  |> click!("button")
  |> assert_text("2")
  ```

- `Filament.Test.change/3` — triggers a `phx-change` event on a form element.
- `Filament.Test.blur/2` — triggers a `phx-blur` event on an element.
- `Filament.Test.key_down/3` — element-scoped `phx-keydown` (3-arity, alongside
  the existing 2-arity window-scoped `key_down/2`).

### Fixed

- Fixed event handler index collision between compile-time `on_*` handlers and
  runtime `register_event_handler` calls. Previously, handlers registered inside
  `{for … do}` loops could silently overwrite `on_*` handlers in the same
  component.

## [0.2.1] - 2026-05-07

### Changed

- The project license has changed from Apache-2.0 to MIT.

### Fixed

- `~F` formatter now preserves `<script>` block content verbatim. Previously,
  JavaScript inside colocated `<script :type={ColocatedHook}>` blocks was
  re-indented as if it were HTML, corrupting indentation-sensitive code.

## [0.2.0] - 2026-05-06

### Added

- `use_observable/2` now accepts a positional projection fn as its second argument. The fn
  receives `:disconnected` when the server is unavailable, or the raw server state otherwise,
  and its return value becomes the hook's result:

  ```elixir
  count = use_observable(CartServer, fn
    :disconnected -> 0
    state -> Cart.State.item_count(state)
  end)
  ```

- `static_subscribe` option on `Filament.LiveView` (default: `true`) controls whether the
  HTTP render pass subscribes to observables. Set to `false` on a live view to prevent
  double-counting presence or other mount side effects on page reload — subscriptions are
  then established only once the WebSocket session connects.

- Support for `<script :type={Phoenix.LiveView.ColocatedHook}>` in `~F` templates.
  Modules using `use Filament.Component` now correctly register colocated JS hooks
  alongside those from `use Phoenix.Component`.

### Changed

- Projection fns now run **client-side at render time** rather than server-side at broadcast
  time. This means a projection fn can close over local component state (filters, selections,
  etc.) so changing that local state correctly re-projects without a new server broadcast.
  The server sends raw state; change-or-bust comparison is `new_raw_state !== last_raw_state`
  per subscriber.

- `handle_subscribe/3` → `handle_subscribe/2`: the `request` argument has been removed.
  Update your `Observable.GenServer` implementations:

  ```elixir
  # before
  def handle_subscribe(_request, _subscriber, state), do: {:ok, state, state}

  # after
  def handle_subscribe(_subscriber, state), do: {:ok, state, state}
  ```

- `Observable.subscribe/3` → `Observable.subscribe/2`: the `request` argument has been removed.
- `Observable.remove_projection/5` → `Observable.remove_projection/4`: the `request` argument
  has been removed.
- `Subscriber` struct: `request` and `projections` fields replaced by `proj_keys` and `last_raw`.

- `~F` templates no longer accept `@foo` assign syntax — use bare lexical variables from
  destructured function arguments instead. `@foo` in a `~F` template now raises a compile
  error. `{if … do}`, `{for … do}`, `{else}`, and `{end}` are handled natively by the tag
  engine rather than via a regex preprocessing pass (no behaviour change for existing templates).

### Removed

- The `request` parameter has been removed from the entire observable stack
  (`handle_subscribe`, `Observable.subscribe`, `Observable.remove_projection`, `Subscriber`
  struct).

### Fixed

- Fixed `keyed_list` removal leaking observable projection keys, causing stale subscriptions
  when list items are removed.

## [0.1.0] - 2026-05-01

### Added
- Initial project scaffold
- Mix project structure with Elixir 1.17+ and OTP 26+ support
- GitHub Actions CI with matrix testing
- ExDoc configuration for documentation
- Basic supervision tree structure
