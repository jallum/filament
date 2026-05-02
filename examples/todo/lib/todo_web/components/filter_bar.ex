defmodule TodoWeb.Components.FilterBar do
  @moduledoc """
  Self-contained filter bar component.

  Demonstrates:
    * use_state owned by a child component
    * Variable filter entries via a keyword-list prop ({atom, label} pairs)
    * on_change callback to notify the parent of selection changes
    * Sub-component (FilterItem) for per-item fiber isolation
  """
  use Filament.Component

  alias TodoWeb.Components.FilterItem

  defcomponent do
    prop(:filters, :list, required: true)
    prop(:default, :atom, default: nil)
    prop(:on_change, :function, default: nil)

    def render(%{filters: filters, on_change: on_change, default: default}) do
      {current, set_current} = use_state(default)

      ~F"""
      <ul class="filters">
        {for {value, label} <- filters do}
          <FilterItem
            value={value}
            label={label}
            is_active={current == value}
            on_click={fn ->
              set_current.(value)
              if on_change, do: on_change.(value)
            end}
          />
        {end}
      </ul>
      """
    end
  end
end
