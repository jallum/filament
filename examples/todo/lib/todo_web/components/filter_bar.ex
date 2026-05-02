defmodule TodoWeb.Components.FilterBar do
  @moduledoc """
  Self-contained filter bar component.

  Demonstrates:
    * use_state owned by a child component
    * Variable filter entries via a keyword-list prop ({atom, label} pairs)
    * on_change callback to notify the parent of selection changes
  """
  use Filament.Component

  import Filament.Hooks

  defcomponent FilterBar do
    prop(:filters, :list, required: true)
    prop(:default, :atom, default: nil)
    prop(:on_change, :function, default: nil)

    def render(%{filters: filters, on_change: on_change, default: default}) do
      {current, set_current} = use_state(default)

      handlers =
        Enum.map(filters, fn {value, _} ->
          fn ->
            set_current.(value)
            if on_change, do: on_change.(value)
          end
        end)

      ~F"""
      <ul class="filters">
        {for {{value, label}, handler} <- Enum.zip(filters, handlers) do}
          <li>
            <a
              class={if current == value, do: "selected", else: ""}
              on_click={handler}
              href="#"
            >{label}</a>
          </li>
        {end}
      </ul>
      """
    end
  end
end
