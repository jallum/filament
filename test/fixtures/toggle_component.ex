defmodule Filament.Fixtures.ToggleComponent do
  @moduledoc """
  Test fixture: Toggle component using use_state
  """
  use Filament.Component

  defcomponent __MODULE__ do
    prop(:label, :string, required: true)

    def render(%{label: _label} = assigns) do
      {open, _set_open} = Filament.Hooks.use_state(false)

      ~F"""
      {open}
      """
    end
  end
end
