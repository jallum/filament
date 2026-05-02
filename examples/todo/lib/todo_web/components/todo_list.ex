defmodule TodoWeb.Components.TodoList do
  @moduledoc """
  Todo list component demonstrating Filament hooks, observables, and event handling.
  """
  use Filament.Component

  alias Filament.Hooks

  defcomponent TodoList do
    prop(:store, :any, required: true)
    prop(:title, :string, default: "Todo List")

    def render(assigns) do
      store = Map.get(assigns, :store)

      # Hooks must be called at top level of render/1, in consistent order
      todos = Hooks.use_observable(store, nil, project: &Function.identity/1)
      {filter, set_filter} = Hooks.use_state(:all)
      {input_text, set_input_text} = Hooks.use_state("")

      # Pre-filter todos based on filter value
      filtered_todos =
        case filter do
          :active -> Enum.reject(todos, & &1.completed)
          :completed -> Enum.filter(todos, & &1.completed)
          _ -> todos
        end

      # Derive stats
      active_count = Enum.count(todos, &(!&1.completed))
      all_completed? = todos != [] and Enum.all?(todos, & &1.completed)

      # Build filter CSS classes
      all_class = if filter == :all, do: "selected", else: ""
      active_class = if filter == :active, do: "selected", else: ""
      completed_class = if filter == :completed, do: "selected", else: ""

      # Event handlers for filter buttons
      all_handler = fn -> set_filter.(:all) end
      active_handler = fn -> set_filter.(:active) end
      completed_handler = fn -> set_filter.(:completed) end

      # Build todo item HTML strings (avoid Phoenix variable warnings)
      items_html =
        Enum.map(filtered_todos, fn todo ->
          class_str = if todo.completed, do: "completed", else: ""

          # Build the HTML manually as iodata for efficiency
          [
            "<li class=\"",
            class_str,
            "\">",
            "<div class=\"view\">",
            "<input class=\"toggle\" type=\"checkbox\"",
            if(todo.completed, do: " checked", else: ""),
            " phx-click=\"toggle:",
            Integer.to_string(todo.id),
            "\" />",
            "<label>",
            Phoenix.HTML.Engine.encode_to_iodata!(todo.text),
            "</label>",
            "<button class=\"destroy\" phx-click=\"remove:",
            Integer.to_string(todo.id),
            "\">×</button>",
            "</div>",
            "</li>"
          ]
        end)

      # Merge all values into assigns for template access
      assigns =
        Map.merge(assigns, %{
          todos: todos,
          filtered: filtered_todos,
          items_html: items_html,
          input_text: input_text,
          filter: filter,
          active_count: active_count,
          all_completed: all_completed?,
          all_class: all_class,
          active_class: active_class,
          completed_class: completed_class,
          set_input_text: set_input_text,
          all_handler: all_handler,
          active_handler: active_handler,
          completed_handler: completed_handler
        })

      ~F"""
      <section class="todoapp">
        <header class="header">
          <h1>{@title}</h1>
          <form phx-submit="add_todo">
            <input
              name="text"
              class="new-todo"
              placeholder="What needs to be done?"
              value={@input_text}
              autofocus
            />
          </form>
        </header>

        <%= if @todos != [] do %>
          <section class="main">
            <input class="toggle-all" type="checkbox" checked={@all_completed} />
            <ul class="todo-list">
              <%= Phoenix.HTML.raw(@items_html) %>
            </ul>
          </section>

          <footer class="footer">
            <span class="todo-count"><strong>{@active_count}</strong> item(s) left</span>
            <ul class="filters">
              <li>
                <a class={@all_class} on_click={@all_handler} href="#">
                  All
                </a>
              </li>
              <li>
                <a class={@active_class} on_click={@active_handler} href="#">
                  Active
                </a>
              </li>
              <li>
                <a class={@completed_class} on_click={@completed_handler} href="#">
                  Completed
                </a>
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

    def handle_event("toggle:" <> id_str, _params, %{store: store} = props) do
      id = String.to_integer(id_str)
      Todo.Store.toggle(store, id)
      {props, :ok}
    end

    def handle_event("remove:" <> id_str, _params, props) do
      store = Map.get(props, :store)
      id = String.to_integer(id_str)
      Todo.Store.remove(store, id)
      {props, :ok}
    end
  end
end
