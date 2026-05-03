defmodule CollaborationWeb.CollaborationLive do
  @moduledoc false
  use Filament.LiveView

  import Phoenix.Component

  def mount(params, session, socket) do
    doc_id = Map.get(params, "doc_id", "demo-doc")
    socket = assign(socket, :doc_id, doc_id)
    super(params, session, socket)
  end

  def root_component, do: CollaborationWeb.Components.DocumentEditor
end
