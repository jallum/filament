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
