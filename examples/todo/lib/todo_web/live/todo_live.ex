defmodule TodoWeb.TodoLive do
  use Filament.LiveView

  def mount(_params, _session, socket) do
    # The Todo.Store must be started manually since we can't do it in the
    # overridden Filament.LiveView mount via Reconciler. We'll start it here
    # and pass it as a prop.
    {:ok, store} = Todo.Store.start_link([])
    Process.link(store)

    socket = assign(socket, :store, store)
    super([], %{}, socket)
  end

  def root_component, do: TodoWeb.Components.TodoList.TodoList
end
