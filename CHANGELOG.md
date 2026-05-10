# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

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
