defmodule TodoWeb.Components.TodoList do
  @moduledoc """
  Todo list component using VNodeCompiler templates and TodoItem child components.
  """
  use Filament.Component

  alias Todo.Store
  alias TodoWeb.Components.FilterBar
  alias TodoWeb.Components.TodoItem

  defcomponent do
    prop(:title, :string, default: "Todo List")

    def render(%{title: title}) do
      source =
        use_source(fn ->
          {:ok, pid} = Store.start_link([])
          Store.cell(pid)
        end)

      {filter, set_filter} = use_state(:all)
      {clear_key, bump_clear} = use_state(0)

      # Project everything derived from todos in one shot. change-or-bust
      # suppresses re-renders when todos change but none of the derived values
      # do (e.g. completing a todo while the Active filter is selected leaves
      # filtered, active_count, and all_completed all unchanged).
      {filtered, active_count, all_completed, any_todos} =
        use_value(source, fn
          :disconnected ->
            {[], 0, false, false}

          todos ->
            {
              apply_filter(todos, filter),
              Enum.count(todos, &(!&1.completed)),
              todos != [] and Enum.all?(todos, & &1.completed),
              todos != []
            }
        end)

      on_submit = fn %{"text" => val} ->
        if String.trim(val) != "", do: Store.add(source.data, val)
        bump_clear.(clear_key + 1)
      end

      ~F"""
      <section class="todoapp">
        <header class="header">
          <h1>{title}</h1>
          <form on_submit={on_submit}>
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

        {if any_todos do}
          <section class="main">
            <input
              class="toggle-all"
              type="checkbox"
              checked={all_completed}
              on_click={fn -> Store.toggle_all(source.data, !all_completed) end}
            />
            <ul class="todo-list">
              <TodoItem
                :for={todo <- filtered}
                :key={todo.id}
                todo={todo}
                on_toggle={fn -> Store.toggle(source.data, todo.id) end}
                on_remove={fn -> Store.remove(source.data, todo.id) end}
              />
            </ul>
          </section>

          <footer class="footer">
            <span class="todo-count"><strong>{active_count}</strong> item(s) left</span>
            <FilterBar
              filters={[all: "All", active: "Active", completed: "Completed"]}
              default={:all}
              on_change={set_filter}
            />
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
