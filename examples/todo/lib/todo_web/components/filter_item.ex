defmodule TodoWeb.Components.FilterItem do
  @moduledoc """
  Individual filter button component.

  Demonstrates per-item fiber isolation: each FilterItem gets its own fiber
  and its own compile-time slot layout, independent of its siblings.
  """
  use Filament.Component

  defcomponent do
    prop(:value, :any, required: true)
    prop(:label, :string, required: true)
    prop(:is_active, :boolean, default: false)
    prop(:on_click, :function, required: true)

    def render(%{label: label, is_active: is_active, on_click: on_click}) do
      ~F"""
      <li>
        <a
          class={if is_active, do: "selected", else: ""}
          on_click={on_click}
          href="#"
        >{label}</a>
      </li>
      """
    end
  end
end
