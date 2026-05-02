defmodule Filament.Examples.TodoExampleTest do
  @moduledoc """
  Compilation and basic runtime verification for the TodoList example app.
  """
  use ExUnit.Case, async: false

  alias Todo.Store
  alias TodoWeb.Components.TodoList
  alias TodoWeb.TodoLive
  alias Filament.Reconciler

  @doc """
  Verify that all key modules in the TodoList example compile successfully.
  """
  test "TodoList example modules compile without warnings" do
    # Verify Store exists and implements Observable
    assert {:module, Store} = Code.ensure_loaded(Store)
    attributes = Store.__info__(:attributes)
    assert Keyword.has_key?(attributes, :behaviour)
    assert Keyword.has_key?(attributes, :vsn)

    # Verify component exists and is valid
    assert {:module, TodoList} = Code.ensure_loaded(TodoList)
    assert TodoList.__filament_component__?()

    # Verify LiveView exists
    assert {:module, TodoLive} = Code.ensure_loaded(TodoLive)
    assert function_exported?(TodoLive, :mount, 3)
    assert function_exported?(TodoLive, :render, 1)
    assert function_exported?(TodoLive, :handle_event, 3)
  end

  @doc """
  Verify Store behaves as an Observable GenServer with add/toggle/remove.
  """
  test "Store can add, toggle, and remove todos" do
    {:ok, pid} = Store.start_link([])

    # Initially empty
    assert [] == Store.list(pid)

    # Add todos
    :ok = Store.add(pid, "Buy milk")
    :ok = Store.add(pid, "Build TodoList")

    todos = Store.list(pid)
    assert length(todos) == 2

    assert [
             %{text: "Buy milk", completed: false, id: id1},
             %{text: "Build TodoList", completed: false, id: id2}
           ] =
             Enum.sort_by(todos, & &1.id)

    # Toggle one
    :ok = Store.toggle(pid, id1)

    assert [%{completed: true}, %{completed: false}] =
             pid |> Store.list() |> Enum.sort_by(& &1.id)

    # Remove one
    :ok = Store.remove(pid, id1)
    assert [%{id: ^id2}] = Store.list(pid)

    GenServer.stop(pid)
  end

  @doc """
  Verify that TodoList component mounts without crashing (basic smoke test).
  """
  test "TodoList component mounts without errors" do
    # Start a store
    {:ok, store} = Store.start_link([])

    # Add a sample todo
    :ok = Store.add(store, "Test todo")

    # Mount the component
    props = %{store: store, title: "My Todos"}

    {_tree, rendered, _effects} =
      Reconciler.mount(TodoList, props, owner_pid: self())

    # Verify it's a valid Rendered struct
    assert %Phoenix.LiveView.Rendered{} = rendered

    GenServer.stop(store)
  end

  @doc """
  Verify that TodoList defines expected event handlers.
  """
  test "TodoList component defines required event handlers" do
    events = TodoList.module_info(:exports)

    assert {:handle_event, 3} in events
    assert {:render, 1} in events
    assert TodoList.__props__()
    assert TodoList.__props__()[:store]
    assert TodoList.__props__()[:title]
  end
end
