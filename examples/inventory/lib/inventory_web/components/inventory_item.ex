defmodule InventoryWeb.Components.InventoryItem do
  @moduledoc false
  use Filament.Component

  import InventoryWeb.Hooks

  defcomponent do
    prop(:item_id, :string, required: true)
    prop(:server, :any, required: true)

    def render(%{item_id: item_id, server: server}) do
      noop = fn _ -> :ok end

      {held_qty, item, hold, release} =
        use_hold(
          server,
          item_id,
          disconnected: {0, nil, noop, noop}
        )

      ~F"""
      <div class="inventory-item">
        {if item do}
          <strong>{item.name}</strong>
          <span class="available">{item.available} available</span>
          {if held_qty > 0 do}
            <span class="held">Holding: {held_qty}</span>
            <button on_click={fn -> release.(1) end}>−</button>
          {end}
          {if item.available > 0 do}
            <button on_click={fn -> hold.(1) end}>+</button>
          {else}
            <span class="status out-of-stock">Out of Stock</span>
          {end}
        {end}
      </div>
      """
    end
  end
end
