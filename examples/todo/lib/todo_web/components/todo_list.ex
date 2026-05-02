defmodule TodoWeb.Components.TodoList do
  @moduledoc """
  Todo list component using VNodeCompiler templates and TodoItem child components.
  """
  use Filament.Component

  alias Filament.Hooks
  alias TodoWeb.Components.TodoItem.TodoItem

  defcomponent TodoList do
    prop(:store, :any, required: true)
    prop(:title, :string, default: "Todo List")

    def render(assigns) do
      store = Map.get(assigns, :store)
      title = Map.get(assigns, :title, "Todo List")

      raw = Hooks.use_observable(store, nil, project: &Function.identity/1)
      todos = if raw == :uninitialized, do: [], else: raw

      {filter, set_filter} = Hooks.use_state(:all)

      filtered =
        case filter do
          :active -> Enum.reject(todos, & &1.completed)
          :completed -> Enum.filter(todos, & &1.completed)
          _ -> todos
        end

      active_count = Enum.count(todos, &(!&1.completed))
      all_completed = todos != [] and Enum.all?(todos, & &1.completed)

      all_class = if filter == :all, do: "selected", else: ""
      active_class = if filter == :active, do: "selected", else: ""
      completed_class = if filter == :completed, do: "selected", else: ""

      # Define handlers as variables so VNodeCompiler treats them as variable
      # references (not fn literals), preventing use_memo wrappers that crash
      # during Phoenix's diff-eval pass outside Filament's render context.
      all_handler = fn -> set_filter.(:all) end
      active_handler = fn -> set_filter.(:active) end
      completed_handler = fn -> set_filter.(:completed) end

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

        <%= if todos != [] do %>
          <section class="main">
            <input class="toggle-all" type="checkbox" checked={all_completed} />
            <ul class="todo-list">
              <%= for todo <- filtered do %>
                <%= TodoItem.render(%{
                  todo: todo,
                  on_toggle: fn -> Todo.Store.toggle(store, todo.id) end,
                  on_remove: fn -> Todo.Store.remove(store, todo.id) end
                }) %>
              <% end %>
            </ul>
          </section>

          <footer class="footer">
            <span class="todo-count"><strong>{active_count}</strong> item(s) left</span>
            <ul class="filters">
              <li>
                <a class={all_class} on_click={all_handler} href="#">All</a>
              </li>
              <li>
                <a class={active_class} on_click={active_handler} href="#">Active</a>
              </li>
              <li>
                <a class={completed_class} on_click={completed_handler} href="#">Completed</a>
              </li>
            </ul>
          </footer>
        <% end %>
      </section>
      """
    end

    def handle_event("add_todo", %{"text" => text}, %{store: store} = props) do
      if String.trim(text) != "" do
        Todo.Store.add(store, text)
      end

      {props, :ok}
    end
  end
end
