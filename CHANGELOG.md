# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Changed

- Projection fns now run **client-side at render time** rather than server-side at broadcast
  time. This means a projection fn can close over local component state (filters, selections,
  etc.), so changing that local state correctly re-projects without a new server broadcast.
  The server sends raw state; change-or-bust comparison is now `new_raw_state !== last_raw_state`
  per subscriber.
- `handle_subscribe/3` → `handle_subscribe/2`: the `request` argument has been removed.
  Implementations should update their signatures accordingly:

  ```elixir
  # before
  def handle_subscribe(_request, _subscriber, state), do: {:ok, state, state}

  # after
  def handle_subscribe(_subscriber, state), do: {:ok, state, state}
  ```

- `Observable.subscribe/3` → `Observable.subscribe/2`: the `request` argument has been removed.
- `Observable.remove_projection/5` → `Observable.remove_projection/4`: the `request` argument
  has been removed.
- `Subscriber` struct: `request` and `projections` fields replaced by `proj_keys` and
  `last_raw`.

### Deprecated

### Removed

- `use_projection/3` has been removed. Use `use_observable/2` with a positional projection fn
  instead (see Added above).
- The `request` parameter has been removed from the entire observable stack
  (`handle_subscribe`, `Observable.subscribe`, `Observable.remove_projection`, `Subscriber`
  struct).

### Fixed

### Security

## [0.1.0] - 2026-05-01

### Added
- Initial project scaffold
- Mix project structure with Elixir 1.17+ and OTP 26+ support
- GitHub Actions CI with matrix testing
- ExDoc configuration for documentation
- Basic supervision tree structure
