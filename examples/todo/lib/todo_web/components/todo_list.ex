defmodule TodoWeb.Components.TodoList do
  @moduledoc """
  Todo list component using VNodeCompiler templates and TodoItem child components.
  """
  use Filament.Component

  alias TodoWeb.Components.FilterBar
  alias TodoWeb.Components.TodoItem

  defcomponent do
    prop(:store, :any, required: true)
    prop(:title, :string, default: "Todo List")

    def render(%{store: store, title: title}) do
      raw = use_observable(store, nil, project: &Function.identity/1)
      todos = if raw == :uninitialized, do: [], else: raw

      {filter, set_filter} = use_state(:all)
      filtered = apply_filter(todos, filter)

      active_count = Enum.count(todos, &(!&1.completed))
      all_completed = todos != [] and Enum.all?(todos, & &1.completed)

      ~F"""
      <section class="todoapp">
        <header class="header">
          <h1>{title}</h1>
          <form phx-submit="add_todo">
            <input
              name="text"
              class="new-todo"
              placeholder="What needs to be done?"
              autofocus
            />
          </form>
        </header>

        {if todos != [] do}
          <section class="main">
            <input class="toggle-all" type="checkbox" checked={all_completed} />
            <ul class="todo-list">
              {for todo <- filtered do}
                <TodoItem todo={todo} on_toggle={fn -> Todo.Store.toggle(store, todo.id) end} on_remove={fn -> Todo.Store.remove(store, todo.id) end} />
              {end}
            </ul>
          </section>

          <footer class="footer">
            <span class="todo-count"><strong>{active_count}</strong> item(s) left</span>
            <FilterBar filters={[all: "All", active: "Active", completed: "Completed"]} default={:all} on_change={set_filter} />
          </footer>
        {end}
      </section>
      """
    end

    def handle_event("add_todo", %{"text" => text}, %{store: store} = props) do
      if String.trim(text) != "" do
        Todo.Store.add(store, text)
      end

      {props, :ok}
    end

    defp apply_filter(todos, :all), do: todos
    defp apply_filter(todos, :active), do: Enum.reject(todos, & &1.completed)
    defp apply_filter(todos, :completed), do: Enum.filter(todos, & &1.completed)
  end
end
