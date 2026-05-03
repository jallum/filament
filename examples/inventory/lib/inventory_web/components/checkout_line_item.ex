defmodule InventoryWeb.Components.CheckoutLineItem do
  use Filament.Component

  alias Filament.Hooks

  defcomponent do
    prop(:item_id, :string, required: true)
    prop(:server, :any, default: Inventory.Server)

    def render(%{item_id: item_id, server: server}) do
      hold_acquired =
        try do
          Hooks.use_hold(server, item_id)
          true
        rescue
          Filament.HoldError -> false
        end

      item = Inventory.Server.get_item(server, item_id)

      ~F"""
      <div class="inventory-item">
        {if item do}
          <strong>{item.name}</strong>
          {if hold_acquired do}
            <span class="status available">In Stock ({item.available} available)</span>
          {else}
            <span class="status out-of-stock">Out of Stock</span>
          {end}
        {else}
          <em>Item not found: {item_id}</em>
        {end}
      </div>
      """
    end
  end
end
