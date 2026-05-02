defmodule InventoryWeb.Components.CheckoutLineItem do
  use Filament.Component

  alias Filament.Hooks

  defcomponent CheckoutLineItem do
    prop(:item_id, :string, required: true)
    prop(:server, :any, default: Inventory.Server)

    def render(assigns) do
      item_id = Map.get(assigns, :item_id)
      server = Map.get(assigns, :server)

      # use_hold/3 returns the token, or raises on error.
      # We wrap it in a try/rescue to handle errors gracefully.
      # This is a workaround for the current API limitation.
      {hold_acquired, _token} = 
        try do
          token = Hooks.use_hold(server, item_id)
          {true, token}
        rescue
          Filament.HoldError ->
            {false, nil}
        end

      item = Inventory.Server.get_item(server, item_id)

      assigns = Map.merge(assigns, %{
        hold_acquired: hold_acquired,
        item: item
      })

      # Simple HTML output to avoid template complexity
      if !item do
        ~F"""
        <div>Item not found: <%= @item_id %></div>
        """
      else
        if hold_acquired do
          ~F"""
          <div>
            <span><%= @item.name %></span>
            <span>Available: <%= @item.available %></span>
            <span>Hold acquired</span>
          </div>
          """
        else
          ~F"""
          <div>
            <span><%= @item.name %></span>
            <span>Available: <%= @item.available %></span>
            <span>Out of Stock</span>
          </div>
          """
        end
      end
    end
  end
end
