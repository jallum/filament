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

defmodule Filament.Fixtures.ParentComponent do
  @moduledoc """
  Test fixture: Component that renders a list of children
  """
  use Filament.Component

  defcomponent Parent do
    prop :items, :list, required: true

    def render(assigns) do
      ~F"""
      <ul>
        <.Filament.Fixtures.CounterComponent.Counter.render 
          :for={i <- @items} 
          :key={i} 
          count={i} />
      </ul>
      """
    end
  end
end
