defmodule Filament.Fixtures.CounterComponent do
  @moduledoc """
  Test fixture: Simple counter component
  """
  use Filament.Component

  defcomponent do
    prop(:count, :integer, required: true)

    def render(%{count: count}) do
      ~F"""
      <p>{count}</p>
      """
    end
  end
end
