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
        |> Map.put(:id, Map.get(assigns.todo, :id, nil))
        |> Map.put(:text, Map.get(assigns.todo, :text, ""))
        |> Map.put(:item_class, if(assigns.completed, do: "completed", else: ""))

      ~F"""
      <li class={@item_class}>
        <div class="view">
          <input
            class="toggle"
            type="checkbox"
            checked={@completed}
            on_click={@on_toggle}
          />
          <label>{@text}</label>
          <button class="destroy" phx-click={"remove:" <> Integer.to_string(@id)}>
            ×
          </button>
        </div>
      </li>
      """
    end
  end
end
