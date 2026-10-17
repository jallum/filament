# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A `use_state` setter takes a function of the current value. A handler
  sees the value of the render that made it, and when two events reach the
  view before the first one's update is applied, both handlers saw the same
  value and one update was lost. A function applies to the value as it is
  when the update lands:

  ```elixir
  # Before: two quick clicks could count once
  on_click={fn -> set_count.(count + 1) end}

  # After
  on_click={fn -> set_count.(&(&1 + 1)) end}
  ```

  A function passed to a setter is always applied; to keep a function as
  the state, wrap it: `set_callback.(fn _old -> callback end)`.

- `Filament.Test.await/3` returns the view once a condition holds, applying
  Filament messages as they arrive, and raises with the view's text on
  timeout. Tests no longer loop over `update/1` or match Filament's
  message tuples to wait for a page:

  ```elixir
  view = await(view, &(render_text(&1) =~ "3 results"))
  ```

- `use_value/3` takes `disconnected: value`, returned while the source is
  `nil`, disconnected or unreachable, so the projection handles only the
  source's values:

  ```elixir
  # Before
  count = use_value(source, fn :disconnected -> 0; s -> s.count end)

  # After
  count = use_value(source, & &1.count, disconnected: 0)
  ```

- `Filament.Hooks.use_identity/0` returns `{owner_pid, fiber_id}` for the
  calling component, the pair a server's subscriber terms start with, so a
  server can key per-component state by it and clear it in
  `handle_unsubscribe/2`. It replaces reading the undocumented
  `current_context()`, which `import Filament.Hooks` no longer brings in:

  ```elixir
  # Before
  holder = {current_context().owner_pid, current_context().fiber_id}

  # After
  holder = use_identity()
  ```

- `Filament.Observable.GenServer.cell/1` builds the source for any server
  using `Filament.Observable.GenServer`, for code that doesn't know which
  server module it holds. `MyServer.cell/1` still builds the same source.

- `Filament.Component.props/1` names the props a component declares, in
  place of calling the generated `__props__/0`.

- `Filament.KeyModifiers`, the struct an `on_key` handler receives, is
  documented.

### Changed

- `Filament.Test.update/1`, and events such as `click/2`, render until no
  Filament message is left, so state an effect sets shows in the view they
  return; one render could leave its effects' messages in the mailbox.

- **Breaking:** `handle_subscribe/2` returns `{:ok, new_state}` to accept,
  without a value; a subscriber starts from `handle_current/1`'s value, as
  refreshes and `Filament.Cell.current/2` do. With the value in two
  callbacks, a server that overrode only `handle_subscribe/2` published one
  value on subscribe and its whole state on a refresh. A server returning
  the old `{:ok, value, state}` raises, naming `handle_current/1`:

  ```elixir
  # Before (0.6.0-rc.3)
  def handle_subscribe(_subscriber, state), do: {:ok, state.held, state}

  # After
  def handle_current(state), do: {:ok, state.held, state}
  ```

- `import Filament.Hooks` (and `use Filament.Component`) no longer imports
  the undocumented `use_slot/1`, `commit_slot/2` and `current_context/0`,
  which the hooks are built from. See `use_identity/0` above.

### Deprecated

### Removed

- `Filament.Test.LiveView` and `Filament.Test.LiveView.Helpers`. Its
  `use Phoenix.LiveViewTest` doesn't compile under LiveView 1.2, and its
  helpers wrapped single `Phoenix.LiveViewTest` calls; use
  `Phoenix.LiveViewTest` directly.

### Fixed

- A `use_value` that couldn't subscribe waits for its backoff (100 ms,
  doubling to 5 s) before subscribing again, as documented. Any render of
  its component subscribed again at once, and against a server that was
  alive but stuck, each such render blocked the view for the call's 5 s
  timeout.

- Slots behave as in HEEx in three more places:
  - A self-closing `<:name />` directly inside a component tag is an entry
    with no content. It was a render site, passing the enclosing
    component's own `name` slot as the child's `children`.
  - A render site inside a slot entry's content, such as
    `<:item><li><:title /></li></:item>`, renders the slot of the template's
    own component. It read the props of the component rendering the entry.
  - `slot :name, default: Mod` renders `Mod` when no entry is given, as the
    render site's `default={Mod}` does. The declared default was ignored.

- A hook a render stops calling, such as a `use_effect` or `use_value`
  under an `if`, is cleaned up by that render: the effect's cleanup runs
  and the subscription ends. Both lasted until the view exited, and an
  effect queued before it was dropped still ran.

- `~F` rejects HEEx syntax it has no meaning for, at compile time, where it
  used to reinterpret or drop it:
  - `<.name />` raised nothing and rendered the module's own `render/1`;
    render a component module with `<Module />`.
  - `:key`, `:let` and other `:`-attributes on a slot entry were dropped;
    `:if` and `:for` remain.
  - A self-closing `<script :type={...} />` emitted a literal `:type`
    attribute; a macro component needs a closing tag.
  - An `id` beside `on_key`, which sets the id, produced two `id`
    attributes.
  - `on_key` in an attribute spread rendered LiveView's `phx-key` filter
    and never fired; it now raises at render.

- `Filament.LiveView.put_props/2` called from `handle_params/3` on a
  connected mount no longer drops the mount's effects. Phoenix calls
  `handle_params/3` before the first render, and the props' render replaced
  the effects the mount had queued. Effects queued by several renders
  before one now all run, each calling the cleanup of the run before it,
  and `put_props/2` with unchanged props doesn't render.

### Security

## [0.6.0-rc.3] - 2026-10-14

### Fixed

- `on_key` works again without anything in the layout. 0.6.0-rc.1 moved the
  `FilamentKey` hook's script out of `Filament.LiveView`'s output into
  `Filament.LiveView.runtime_assets/1`, without saying so, and an app whose
  layout didn't render it had keys silently ignored. The script is again
  part of the view's static output, which LiveView sends once per mount,
  not with each diff. A layout that renders `runtime_assets/1` can keep it
  or drop it; a `Filament.LiveComponent` inside a LiveView of your own
  still needs it.

## [0.6.0-rc.2] - 2026-10-14

### Added

- `Filament.LiveView.put_props/2` merges props into the root component's
  and renders it again, from the view's own callbacks. It replaces 0.5.x's
  injected private `rerender_from_root/2`, which 0.6.0-rc.1 removed without
  a replacement; the usual caller is `handle_params/3`:

  ```elixir
  def handle_params(params, _uri, socket) do
    {:noreply, Filament.LiveView.put_props(socket, params: params)}
  end
  ```

  During the static render it reads sources as the view's mount did, so a
  `handle_params/3` there doesn't subscribe.

- `Filament.Test.mount/3` takes `cells: %{server => stub_pid}`, answering
  one server's subscriptions from a `Filament.Test.Stub` while the
  component's own calls to the server still reach it. Passing the stub as
  the prop, as 0.6.0-rc.1 suggested, breaks a component that also reads the
  server it subscribes to:

  ```elixir
  {:ok, stub} = Filament.Test.Stub.start(fn _ -> {:loading, %{phase: :scanning}} end)
  view = mount!(QueuePage, %{catalog: catalog}, cells: %{catalog => stub})
  ```

  It applies to `Filament.Observable.GenServer` sources, in any component
  of the view, and replaces 0.5.x's `:stub` option.

### Fixed

- An `on_*` attribute given a literal `fn` no longer gets a type warning
  under Elixir 1.20 for the `nil`/`false` check `~F` generates around it.

## [0.6.0-rc.1] - 2026-10-14

### Added

- A target-independent vnode renderer and `Filament.Core` event dispatcher,
  with capture/bubble phases and `stop_propagation/1`. Phoenix LiveView and
  LiveComponent convert resolved vnodes through `Filament.Web`.

- `%Filament.Source{}` and the `Filament.Cell` transport behaviour for reactive
  values beyond GenServers.

- `use_source/1,2` to bind a source, including factories keyed by resource
  identity, and `use_value/2` to subscribe and project its value. The examples
  show custom domain hooks that hide source construction from components.

- `Filament.LiveView` unmounts its tree in `terminate/2`, running effect
  cleanups when the client disconnects. `Filament.Test.unmount/1` does the
  same for a test view.

- `use_value/2` reconnects. It monitors the process behind a source, through
  the optional `Filament.Cell.whereis/1` callback, and subscribes again when
  that process exits, so a server restarted under a name or via-tuple
  reaches its readers without a reload. A subscribe that can't reach its
  source retries with backoff (100 ms doubling to 5 s) until it connects or
  the reader unmounts; so does one whose `handle_subscribe/2` rejected it.

### Changed

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

- **Breaking:** component `render/1` and `Reconciler.mount/3` / `update/4`
  produce vnode output. Low-level callers use `Filament.Web.to_rendered/1`
  or `to_iodata/1` for Phoenix/HTML output; the adapters do this automatically.

- `Filament.LiveView` and `Filament.LiveComponent` send only what changed
  since the last frame. They keep the complete output last sent and diff
  the next one against it, so an unchanged subtree sends nothing, however
  the tree around it rendered. `:for` loops of markup and of components are
  sent as LiveView comprehensions: keyed rows are patched by key, so a move
  or insert sends no unchanged row, and rows without `:key` by position.
  Loops of markup inside `{if}`, `{case}` and `{cond}` branches compile the
  same way. A dynamic attribute is one slot, as in HEEx, so a `nil`,
  `false`, `true` or keyword-list value doesn't change the row's shape.
  Rows that repeat a key are sent as one block as before.

- **Breaking:** replace `use_observable/1,2` with `use_source/1,2` and
  `use_value/2`. Sources are structs, not `{transport, data}` tuples:

  ```elixir
  # Before (0.5.x)
  count = use_observable(server, fn :disconnected -> 0; s -> s.count end)

  # After
  source = MyServer.cell(server)
  count = use_value(source, fn :disconnected -> 0; s -> s.count end)
  ```

  When resolving a server from an identifier, put
  `use_source(fn -> MyServer.cell(id) end, id)` inside a domain hook.
  See the migration guide for the full 0.5.x upgrade.

- Reactive hooks subscribe to raw state and run the user projection during
  rendering, so projections can capture current local state. Equal raw writes
  produce no delivery. A changed raw value is kept in the slot but skips the
  render when every projected value is unchanged (`===`), as in 0.5.6.

- **Breaking:** `handle_unsubscribe/2` receives the opaque subscriber tuple
  `{owner_pid, fiber_id, slot_index, generation}`. Destructure this tuple rather
  than reading the former `Subscriber.pid` field.

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

- **Breaking:** a slot entry (`<:header>`) must be a direct child of its
  component, as in HEEx; inside `{if}`, `{for}`, `{case}` or an element it
  was hoisted out and rendered regardless. Use `:if` or `:for` on the entry.
  A tag opened in a block must close in it; both are now syntax errors with
  a location instead of compiler crashes.

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

- **Breaking:** requires Erlang/OTP 27 or later, for the tagged monitors
  that reconnect `use_value/2`, and `phoenix_live_view` `~> 1.2.0`.
  Filament uses LiveView's template tokenizer and diff structures, which
  can change between minor versions, so each new minor is supported once
  it has been tested.

- `Filament.SigilFFormatter` formats heredoc `~F"""` templates with
  `Phoenix.LiveView.HTMLFormatter`. Its own formatter returned every
  template unchanged on LiveView 1.2. One-line templates and templates with
  `{for}`, `{if}`, `{case}` or `{cond}` blocks are left as written. Run
  `mix format --force` once after upgrading (`mix format` caches results per
  file): heredoc templates are reindented as `~H` templates would be.

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

- A saturated subscriber gets one recovery notice per episode, and delivery
  resumes from fresh state after it resubscribes.

- Removed descendants run cleanup exactly once; keyed descendants retain
  state, and stale messages from replaced subscriptions are ignored.

- LiveComponent handles batched Cell updates while preserving its root output.

- A cell server no longer crashes notifying a subscriber on another node.

- `Filament.LiveComponent` renders inside a real LiveView, whose diff engine
  requires a single root tag. A component rendering one element is marked
  as rooted.

- A component whose `render/1` returns `false` renders nothing, as `nil`
  does.

- Keyed components whose keys differ only beyond `inspect/1`'s default
  limits, or in struct fields hidden by a custom `Inspect`, get separate
  fibers.

- A click on a handler removed by a later render runs nothing; it no longer
  fires the capture handlers of the target's ancestors. `Filament.Test`
  runs handlers taking a push function, sending `{:push_event, event,
  payload}` to the test process.

- A `Filament.LiveView` receiving a message it doesn't handle logs it and
  continues, as Phoenix does, instead of crashing. A view with its own
  `handle_info/2` ends with `def handle_info(msg, socket), do: super(msg, socket)`.

- `Filament.LiveComponent` remounts when its `component` assign changes,
  instead of rendering the new component with the old one's tree.

- HTML loop `:key` expressions are evaluated in generator scope, avoiding
  unused-variable warnings for bindings used only by the key.

- The 0.5.6 observable fixes apply on the cell transport: the injected
  cell subscribe, current-value, unsubscribe and `:DOWN` handlers keep
  the server's `timeout/1`, and a cell subscriber that has exited is
  skipped quietly until its `:DOWN`.

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
