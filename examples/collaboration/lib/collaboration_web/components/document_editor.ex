defmodule CollaborationWeb.Components.DocumentEditor do
  @moduledoc false
  use Filament.Component

  alias Collaboration.DocumentServer

  defcomponent do
    prop(:doc_id, :string, required: true)

    def render(%{doc_id: doc_id}) do
      cell = use_observable({Filament.Observable.GenServer, DocumentServer.via_registry(doc_id)})

      server = DocumentServer.via_registry(doc_id)

      # NOTE: This LiveView uses static_subscribe: false (see CollaborationLive).
      # With the default (static_subscribe: true), the HTTP render process would
      # call handle_subscribe and increment presence before the old WebSocket tears
      # down on reload, producing a momentary 1→2→1 spike. Setting
      # static_subscribe: false means this projection returns :disconnected during
      # the HTTP render and only subscribes once the real WebSocket session is
      # established — so the presence count always reflects live connections only.
      #
      # We return a neutral struct for :disconnected so the static HTML contains the
      # full document structure. The first-load WS patch then only updates the dynamic
      # leaves (presence text, lock badge) rather than replacing the entire layout.
      doc_view =
        use_observable(cell, fn
          :disconnected -> %{presence: 0, locked: false, lock_holder: nil}
          s -> s
        end)

      ~F"""
      <div class="doc-editor">
        <div class="doc-header">
          <h1>Document: {doc_id}</h1>
          <span class="presence">{presence_text(doc_view.presence)}</span>
        </div>

        <div class="doc-body">
          <p class="doc-placeholder">— document content would appear here —</p>
        </div>

        <div class="doc-footer">
          {if doc_view.locked do}
            {if doc_view.lock_holder == self() do}
              <span class="lock-badge locked">Editing</span>
              <span class="lock-holder">held by you</span>
              <button class="btn btn-release" on_click={fn -> DocumentServer.release_lock(server, self()) end}>Release</button>
            {else}
              <span class="lock-badge locked">Locked</span>
              <span class="lock-holder">held by {format_holder(doc_view.lock_holder)}</span>
              <button class="btn btn-disabled" disabled>Edit</button>
            {end}
          {else}
            <span class="lock-badge unlocked">Available</span>
            <button class="btn btn-primary" on_click={fn -> DocumentServer.acquire_lock(server, self()) end}>Edit</button>
          {end}
        </div>
      </div>
      """
    end

    defp presence_text(1), do: "1 user viewing"
    defp presence_text(n), do: "#{n} users viewing"

    defp format_holder(nil), do: "unknown"

    defp format_holder(pid) when is_pid(pid) do
      case :rpc.call(node(), Process, :info, [pid, :registered_name]) do
        {:registered_name, name} when name != [] ->
          inspect(name)

        _ ->
          [_, b, c] = pid |> :erlang.pid_to_list() |> List.to_string() |> String.split(".")
          "session #{b}.#{String.trim_trailing(c, ">")}"
      end
    end

    defp format_holder(other), do: inspect(other)
  end
end
