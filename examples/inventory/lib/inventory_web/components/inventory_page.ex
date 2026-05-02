defmodule InventoryWeb.Components.InventoryPage do
  use Filament.Component

  defcomponent InventoryPage do
    prop(:server, :any, default: Inventory.Server)

    def render(assigns) do
      server = Map.get(assigns, :server)

      item_ids = ["apple", "banana", "cherry"]

      items_html =
        Enum.map(item_ids, fn id ->
          item = Inventory.Server.get_item(server, id)

          if item do
            status =
              if item.available > 0 do
                "<span style='color:green'>In Stock (#{item.available} available)</span>"
              else
                "<span style='color:red'>Out of Stock</span>"
              end

            """
            <div class="item" style="padding:8px 0;border-bottom:1px solid #eee">
              <strong>#{item.name}</strong>
              <span class="hold-status" style="margin-left:12px">#{status}</span>
            </div>
            """
          else
            "<div class='item'><em>#{id} not found</em></div>"
          end
        end)
        |> Enum.join("\n")

      assigns = Map.put(assigns, :items_html, items_html)

      ~F"""
      <div>
        <h1>Inventory Demo</h1>
        <p>Live inventory status (reads from <code>Inventory.Server</code>):</p>
        <%= Phoenix.HTML.raw(@items_html) %>
        <p style="margin-top:1rem;color:#666;font-size:0.9em">
          Unit tests validate <code>use_hold</code> acquire/release and process-death release.
        </p>
      </div>
      """
    end
  end
end
