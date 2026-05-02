defmodule CartWeb.Components.CartView do
  use Filament.Component

  alias Filament.Hooks

  defcomponent do
    prop(:server, :any, default: Cart.Server)

    def render(assigns) do
      server = Map.get(assigns, :server)

      # No projection — subscribe to full state.
      cart = Hooks.use_observable(server)

      # Build cart item HTML as iodata (avoid Phoenix variable warnings)
      items_html =
        if cart == :uninitialized do
          []
        else
          Enum.map(cart.items, fn item ->
            item_id = item.id
            item_name = item.name
            item_qty = item.quantity
            item_total = div(item.price_cents * item.quantity, 100)
            
            # Build HTML manually as iodata
            [
              "<li class=\"cart-item\" id=\"cart-item-",
              item_id,
              "\">",
              Phoenix.HTML.Engine.encode_to_iodata!(item_name),
              " × ",
              Integer.to_string(item_qty),
              " — ",
              Integer.to_string(item_total),
              " USD",
              "<button class=\"remove\" phx-click=\"remove:",
              item_id,
              "\">Remove</button>",
              "</li>"
            ]
          end)
        end

      assigns =
        Map.merge(assigns, %{
          cart: cart,
          items_html: items_html
        })

      ~F"""
      <div class="cart-view">
        <h2>Your Cart</h2>
        <%= if @cart == :uninitialized do %>
          <p>Loading...</p>
        <% else %>
          <ul>
            <%= @items_html %>
          </ul>
          <p class="total">
            Total: <%= div(@cart.total_cents, 100) %> USD
          </p>
        <% end %>
      </div>
      """
    end

    def handle_event("remove:" <> id_str, _, props) do
      server = Map.get(props, :server)
      Cart.Server.remove_item(server, id_str)
      {props, :ok}
    end
  end
end
