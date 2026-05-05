defmodule CollaborationWeb.CollaborationLive do
  @moduledoc false
  # static_subscribe: false — presence should only count live WebSocket connections.
  # With the default (true), the static HTTP render subscribes and handle_subscribe
  # increments presence *before* the old tab's WS tears down on reload, causing a
  # visible 1→2→1 flash. Disabling static subscribe means the initial HTML shows the
  # :disconnected fallback briefly, but the count is always semantically correct.
  use Filament.LiveView, static_subscribe: false

  import Phoenix.Component

  def mount(params, session, socket) do
    doc_id = Map.get(params, "doc_id", "demo-doc")
    socket = assign(socket, :doc_id, doc_id)
    super(params, session, socket)
  end

  def root_component, do: CollaborationWeb.Components.DocumentEditor
end
