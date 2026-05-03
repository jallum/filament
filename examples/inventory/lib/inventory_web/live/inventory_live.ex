defmodule InventoryWeb.InventoryLive do
  use Filament.LiveView
  def root_component, do: InventoryWeb.Components.InventoryPage
end
