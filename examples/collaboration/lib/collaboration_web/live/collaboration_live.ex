defmodule CollaborationWeb.CollaborationLive do
  @moduledoc false
  # The static HTTP render reads the document's current view without
  # subscribing, so presence counts only WebSocket viewers.
  use Filament.LiveView

  import Phoenix.Component

  def mount(params, session, socket) do
    doc_id = Map.get(params, "doc_id", "demo-doc")
    socket = assign(socket, :doc_id, doc_id)
    super(params, session, socket)
  end

  def root_component, do: CollaborationWeb.Components.DocumentEditor
end
