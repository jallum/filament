defmodule CollaborationWeb.Components.DocumentEditor do
  @moduledoc false
  use Filament.Component

  alias Collaboration.DocumentServer

  defcomponent do
    prop(:doc_id, :string, required: true)

    def render(%{doc_id: doc_id}) do
      source = use_source(DocumentServer.cell(doc_id))

      # A neutral struct for :disconnected keeps the full document structure
      # in the HTML even when the server is unreachable.
      doc_view =
        use_value(source, fn
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
              <button class="btn btn-release" on_click={fn -> DocumentServer.release_lock(source.data, self()) end}>Release</button>
            {else}
              <span class="lock-badge locked">Locked</span>
              <span class="lock-holder">held by {format_holder(doc_view.lock_holder)}</span>
              <button class="btn btn-disabled" disabled>Edit</button>
            {end}
          {else}
            <span class="lock-badge unlocked">Available</span>
            <button class="btn btn-primary" on_click={fn -> DocumentServer.acquire_lock(source.data, self()) end}>Edit</button>
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
