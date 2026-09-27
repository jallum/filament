defmodule Filament.RenderTarget do
  @moduledoc """
  Adapter for producing target output during component reconciliation.

  A target receives raw component output and the active render context. It
  traverses that output, calling `Filament.Renderer.render_component_child/4`
  for component nodes and `Filament.Renderer.resolve_event_attr/1` for event
  attributes. Child components inherit the same target. Hooks, fibers and
  event registration remain owned by the renderer; encoding belongs to the
  target.

  Pass `target: Filament.Web` to `Filament.Reconciler.mount/3` and `update/4`
  to build LiveView output without materializing a walked vnode tree. Omitting
  the target retains the portable walked-vnode output.
  """

  @callback render(term(), Filament.RenderContext.t()) :: term()
end
