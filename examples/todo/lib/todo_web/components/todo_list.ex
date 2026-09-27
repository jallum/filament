defmodule TodoWeb.Components.TodoList do
  @moduledoc """
  Todo list component using VNodeCompiler templates and TodoItem child components.
  """
  use Filament.Component

  import TodoWeb.Hooks, only: [use_todos: 1]

  alias Todo.Store
  alias TodoWeb.Components.FilterBar
  alias TodoWeb.Components.TodoItem

  defcomponent do
    prop(:title, :string, default: "Todo List")

    def render(%{title: title}) do
      {filter, set_filter} = use_state(:all)
      {clear_key, bump_clear} = use_state(0)
      todos = use_todos(filter)

      on_submit = fn %{"text" => val} ->
        if String.trim(val) != "", do: Store.add(todos.store, val)
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

        {if todos.any_todos do}
          <section class="main">
            <input
              class="toggle-all"
              type="checkbox"
              checked={todos.all_completed}
              on_click={fn -> Store.toggle_all(todos.store, !todos.all_completed) end}
            />
            <ul class="todo-list">
              <TodoItem
                :for={todo <- todos.filtered}
                :key={todo.id}
                todo={todo}
                on_toggle={fn -> Store.toggle(todos.store, todo.id) end}
                on_remove={fn -> Store.remove(todos.store, todo.id) end}
              />
            </ul>
          </section>

          <footer class="footer">
            <span class="todo-count"><strong>{todos.active_count}</strong> item(s) left</span>
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
  end
end
