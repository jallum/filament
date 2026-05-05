defmodule Todo.Store do
  @moduledoc """
  Observable GenServer that stores the todo list.
  Used for demonstration of use_observable/2.
  """
  use Filament.Observable.GenServer

  alias Filament.Observable.Subscriber

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{todos: [], next_id: 1}, opts)
  end

  def add(pid, text) when is_binary(text), do: GenServer.call(pid, {:add, text})
  def toggle(pid, id), do: GenServer.call(pid, {:toggle, id})
  def toggle_all(pid, completed), do: GenServer.call(pid, {:toggle_all, completed})
  def remove(pid, id), do: GenServer.call(pid, {:remove, id})
  def list(pid), do: GenServer.call(pid, :list)

  # Server callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:add, text}, _from, state) do
    todo = %{id: state.next_id, text: text, completed: false}
    new_state = %{state | todos: [todo | state.todos], next_id: state.next_id + 1}
    notify_observers(new_state.todos)
    {:reply, {:ok, todo.id}, new_state}
  end

  @impl true
  def handle_call({:toggle, id}, _from, state) do
    new_todos =
      Enum.map(state.todos, fn
        %{id: ^id} = todo -> %{todo | completed: !todo.completed}
        other -> other
      end)

    new_state = %{state | todos: new_todos}
    notify_observers(new_state.todos)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:toggle_all, completed}, _from, state) do
    new_todos = Enum.map(state.todos, &%{&1 | completed: completed})
    new_state = %{state | todos: new_todos}
    notify_observers(new_state.todos)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:remove, id}, _from, state) do
    new_todos = Enum.reject(state.todos, &(&1.id == id))
    new_state = %{state | todos: new_todos}
    notify_observers(new_state.todos)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.todos, state}
  end

  @impl true
  def handle_subscribe(_subscriber, state) do
    {:ok, state.todos, state}
  end
end
