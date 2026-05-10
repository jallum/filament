// Filament runtime assets.
//
// Loaded once by `<Filament.LiveView.runtime_assets />` in the root layout.
// Idempotent — guarded with `||` so re-loading on layout swap is safe.

window.filament = window.filament || {
  // Wire-ref-scoped handleEvent helper for 2-arity event handlers
  // (Filament.Experimental.Hooks.use_event_ref/1). Two instances of the
  // same hook on a page each get their own pushes, scoped by ref.
  handleEvent(hook, event, cb) {
    const ref = hook.el.dataset.ref;
    hook.handleEvent(ref ? ref + ":" + event : event, cb);
  }
};

// FilamentKey: window-level keydown hook for the `on_key` template attr.
// Registered via `data-phx-runtime-hook="FilamentKey"` on the script tag.
window.phx_hook_FilamentKey = window.phx_hook_FilamentKey || function() {
  return {
    mounted() {
      this._handler = (e) => this.pushEvent(
        "filament:" + this.el.dataset.filamentWire,
        { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey, meta: e.metaKey }
      );
      window.addEventListener("keydown", this._handler);
    },
    destroyed() { window.removeEventListener("keydown", this._handler); }
  };
};
