# Module organization: Core vs Web

Filament splits cleanly into a target-agnostic substrate (the **Core**)
and a Phoenix LiveView adapter (the **Web** target). Non-web backends
(TUI, native, embedded) can be built against the same Core without ever
touching anything in the Web column.

The split is enforced at compile time. `test/filament/substrate_boundary_test.exs`
inspects each Core module's BEAM imports list and fails the build if a
new commit accidentally pulls a `Phoenix.LiveView.*` dep into Core.

## Core (substrate)

Target-agnostic. Zero `Phoenix.LiveView.*` imports.

- `Filament.Cell` — the reactivity contract; transports implement it.
- `Filament.Component` / `Filament.Defcomponent` — component definition.
- `Filament.Core` — capture/bubble event dispatcher (`dispatch_event/4`,
  `stop_propagation/1`).
- `Filament.Fiber` / `Filament.FiberTree` — fiber state and lookups.
- `Filament.Hooks` — `use_state`, `use_observable`, `use_cell`, `use_effect`,
  `event_at`, `register_event_handler`, `memo_at`.
- `Filament.KeyModifiers` — keyboard modifier struct used by `on_key`
  handlers.
- `Filament.Observable` / `Filament.Observable.GenServer` /
  `Filament.Observable.Subscriber` — the GenServer-backed Cell transport.
- `Filament.RenderContext` — per-render state.
- `Filament.SigilF` — `~F` macro entry point.
- `Filament.VNode` — IR types and validation.
- `Filament.VNodeCompiler` / `Filament.VNodeEngine` — `~F` codegen.

## Core with web fallbacks

These modules are substrate but each carries a small allowlisted
`Phoenix.LiveView.*` import for backward-compat with mixed Phoenix HEEx
trees. The boundary test enforces the allowlist; new imports outside
it fail CI.

- `Filament.Reconciler` — embeds `%Phoenix.LiveView.Rendered{}` returned
  from a Phoenix HEEx component as an opaque leaf.
- `Filament.Renderer` — same as above, plus `Phoenix.HTML.Safe` for
  html-escaping scalar interpolations.

A pure-substrate variant of these is possible but not yet done; current
behaviour preserves the convenience of mixing Phoenix HEEx components
inside a Filament tree.

## Web (Phoenix LiveView adapter)

Phoenix-specific. Not asserted on by the boundary test — these modules
are *expected* to depend on Phoenix.

- `Filament.HTMLEngine` — HTML attribute handling for `~F` (event-attr
  rewriting, value escaping).
- `Filament.LiveView` — the Phoenix LiveView adapter
  (`use Filament.LiveView` to make a LiveView module).
- `Filament.LiveComponent` — the Phoenix LiveComponent adapter.
- `Filament.TagEngine` — EEx engine for `~F`. Uses
  `Phoenix.LiveView.Tokenizer` to parse the HTML-like syntax (so it's
  technically web-coupled, even though the OUTPUT is substrate vnode IR).
- `Filament.Web` — vnode-to-iodata and vnode-to-`%Rendered{}` converters
  used by the LiveView adapter at the wire boundary.

## Why the names aren't `Filament.Core.*` / `Filament.Web.*`

The substrate stays at top-level (`Filament.Reconciler` rather than
`Filament.Core.Reconciler`) because:

- It's the path users have written against since v0.1.
- Renaming creates churn across every Filament codebase for cosmetic
  benefit.
- The boundary is enforced by the structural test, not by namespace.

`Filament.Web` exists as a namespace for new web-specific machinery
(`Filament.Web.to_iodata/1`, `Filament.Web.to_rendered/1`); pre-existing
web-specific modules (`Filament.LiveView`, etc.) didn't get moved
because there's no functional benefit and it would invalidate
tutorials, blog posts, and downstream code overnight.

If a future major version revisits this, the path would be:

1. Add `Filament.Web.LiveView` as the canonical name with the existing
   `Filament.LiveView` aliasing to it.
2. Deprecate `Filament.LiveView` in a release.
3. Remove the alias in the version after.

## Adding a new backend

To add a non-web backend (say, a TUI):

1. `import` only Core modules. The boundary test guarantees those don't
   pull Phoenix.LiveView in.
2. Implement a `Filament.Cell` transport for whatever push mechanism
   your backend uses (an `Interactive` GenServer, an ETS-backed
   broadcaster, anything).
3. Provide an event source that calls
   `Filament.Core.dispatch_event(tree, target_fiber_id, slot, params)` —
   the dispatcher handles the capture/bubble walk.
4. Add a converter that walks vnode trees into your output medium
   (analogous to `Filament.Web.to_iodata/1`).

OctoPi's `octo_pi_tui2` uses this exact recipe — see its `opi-58c`
tracking ticket for the consumer side.
