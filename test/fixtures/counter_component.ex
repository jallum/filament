defmodule Filament.Fixtures.CounterComponent do
  @moduledoc """
  Test fixture: Simple counter component
  """
  use Filament.Component

  defcomponent Counter do
    prop :count, :integer, required: true

    def render(assigns) do
      ~F"""
      <p>{@count}</p>
      """
    end
  end
end
