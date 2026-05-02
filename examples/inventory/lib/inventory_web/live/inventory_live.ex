defmodule InventoryWeb.InventoryLive do
  use Filament.LiveView

  def mount(params, session, socket) do
    socket = Phoenix.Component.assign(socket, :server, Inventory.Server)
    super(params, session, socket)
  end

  def root_component, do: InventoryWeb.Components.InventoryPage.InventoryPage
end
