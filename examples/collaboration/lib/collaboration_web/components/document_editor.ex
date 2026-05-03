defmodule CollaborationWeb.Components.DocumentEditor do
  use Filament.Component


  defcomponent do
    prop(:doc_id, :string, required: true)
    prop(:server, :any, default: :via_registry)

    def render(%{doc_id: doc_id} = assigns) do
      # Get the server via registry
      server =
        case Map.get(assigns, :server) do
          :via_registry -> Collaboration.DocumentServer.via_registry(doc_id)
          server -> server
        end

      # Subscribe to lock status and presence count.
      doc_view = use_observable(server)

      if doc_view == :disconnected do
        ~F"""
        <div class="document-editor" data-doc-id={@doc_id}>
          <p>Connecting…</p>
        </div>
        """
      else
        # All calculations inside the else block where doc_view is a map
        badge_class = if doc_view.locked, do: "locked", else: "unlocked"

        presence_text =
          if doc_view.presence == 1 do
            "1 user"
          else
            "#{doc_view.presence} users"
          end

        lock_status =
          if doc_view.locked do
            lock_holder = doc_view.lock_holder
            lock_holder_name = if lock_holder, do: inspect(lock_holder), else: "Unknown"

            ~F"""
            <div class="lock-status">
              <span class={badge_class}>🔒 Locked by {lock_holder_name}</span>
              <button class="view-only-btn" disabled="true">Edit (unavailable)</button>
            </div>
            """
          else
            ~F"""
            <div class="lock-status">
              <span class={badge_class}>🔓 Unlocked</span>
              <button class="edit-btn" on_click={fn ->
                Collaboration.DocumentServer.acquire_lock(server, self())
              end}>
                Edit
              </button>
            </div>
            """
          end

        ~F"""
        <div class="document-editor" data-doc-id={@doc_id}>
          <div class="presence">
            {presence_text} here
          </div>
          {lock_status}
        </div>
        """
      end
    end
  end
end
