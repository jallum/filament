defmodule InventoryWeb.Components.CheckoutLineItem do
  use Filament.Component

  alias Filament.Hooks

  defcomponent do
    prop(:item_id, :string, required: true)
    prop(:server, :any, default: Inventory.Server)

    def render(%{item_id: item_id, server: server}) do
      {hold_acquired, _token} =
        try do
          token = Hooks.use_hold(server, item_id)
          {true, token}
        rescue
          Filament.HoldError ->
            {false, nil}
        end

      item = Inventory.Server.get_item(server, item_id)

      if !item do
        ~F"""
        <div>Item not found: {item_id}</div>
        """
      else
        if hold_acquired do
          ~F"""
          <div>
            <span>{item.name}</span>
            <span>Available: {item.available}</span>
            <span>Hold acquired</span>
          </div>
          """
        else
          ~F"""
          <div>
            <span>{item.name}</span>
            <span>Available: {item.available}</span>
            <span>Out of Stock</span>
          </div>
          """
        end
      end
    end
  end
end
