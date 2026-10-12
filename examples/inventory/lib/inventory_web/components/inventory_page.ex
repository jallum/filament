defmodule InventoryWeb.Components.InventoryPage do
  @moduledoc false
  use Filament.Component

  alias InventoryWeb.Components.InventoryItem

  defcomponent do
    prop(:server, :any, default: Inventory.Server)

    def render(%{server: server}) do
      items = Inventory.Server.list_items(server)

      ~F"""
      <div class="inventory-page">
        <h1>Inventory Demo</h1>
        <p>Holds are acquired per-component and released automatically on disconnect.</p>
        <div class="items">
          <InventoryItem :for={item <- items} :key={item.id} server={server} item_id={item.id} />
        </div>
      </div>
      """
    end
  end
end
