defmodule InventoryWeb.InventoryLive do
  @moduledoc false
  use Filament.LiveView

  def root_component, do: InventoryWeb.Components.InventoryPage
end
