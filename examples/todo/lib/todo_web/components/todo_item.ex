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

    def render(assigns) do
      assigns =
        assigns
        |> Map.put(:completed, Map.get(assigns.todo, :completed, false))
        |> then(fn a -> Map.put(a, :item_class, if(a.completed, do: "completed", else: "")) end)

      ~F"""
      <li class={@item_class}>
        <div class="view">
          <input
            class="toggle"
            type="checkbox"
            checked={@completed}
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
