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
      todos = use_observable(store, disconnected: [])

      {filter, set_filter} = use_state(:all)
      {clear_key, bump_clear} = use_state(0)
      filtered = apply_filter(todos, filter)

      active_count = Enum.count(todos, &(!&1.completed))
      all_completed = todos != [] and Enum.all?(todos, & &1.completed)

      ~F"""
      <section class="todoapp">
        <header class="header">
          <h1>{title}</h1>
          <form on_submit={fn %{"text" => val} ->
            if String.trim(val) != "", do: Todo.Store.add(store, val)
            bump_clear.(:erlang.unique_integer([:positive]))
          end}>
            <input
              id="todo-input"
              name="text"
              class="new-todo"
              placeholder="What needs to be done?"
              data-clear-key={clear_key}
              phx-hook="AutoFocus"
            />
          </form>
        </header>

        {if todos != [] do}
          <section class="main">
            <input
              class="toggle-all"
              type="checkbox"
              checked={all_completed}
              on_click={fn -> Todo.Store.toggle_all(store, !all_completed) end}
            />
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

    defp apply_filter(todos, :all), do: todos
    defp apply_filter(todos, :active), do: Enum.reject(todos, & &1.completed)
    defp apply_filter(todos, :completed), do: Enum.filter(todos, & &1.completed)
  end
end
