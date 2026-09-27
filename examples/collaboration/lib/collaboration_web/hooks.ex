defmodule CollaborationWeb.Hooks do
  @moduledoc "Domain hook for the shared document example."

  import Filament.Hooks, only: [use_value: 2]

  alias Collaboration.DocumentServer

  @doc "Return the stable document address and its current view."
  def use_document(doc_id) do
    server = DocumentServer.via_registry(doc_id)

    view =
      use_value(DocumentServer.cell(doc_id), fn
        :disconnected -> %{presence: 0, locked: false, lock_holder: nil}
        state -> state
      end)

    {server, view}
  end
end
