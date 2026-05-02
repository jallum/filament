defmodule TodoWeb.Components.TodoItem do
  @moduledoc """
  Individual todo item component.

  Demonstrates:
    * Prop declarations with prop defaults
    * Simple event callbacks (passed from parent)
  """
  use Filament.Component

  defcomponent TodoItem do
    prop(:todo, :map, required: true)
    prop(:on_toggle, :function, default: nil)
    prop(:on_remove, :function, default: nil)

    defp item_class(%{completed: true}), do: "completed"
    defp item_class(_), do: ""

    def render(%{todo: todo} = assigns) do
      ~F"""
      <li class={item_class(todo)}>
        <div class="view">
          <input
            class="toggle"
            type="checkbox"
            checked={@todo.completed}
            on_click={@on_toggle}
          />
          <label>{@todo.text}</label>
          <button class="destroy" on_click={@on_remove}>×</button>
        </div>
      </li>
      """
    end
  end
end
