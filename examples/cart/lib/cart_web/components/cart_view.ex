defmodule CartWeb.Components.CartView do
  use Filament.Component

  alias Filament.Hooks

  defcomponent do
    prop(:server, :any, default: Cart.Server)

    def render(%{server: server}) do
      cart = Hooks.use_observable(server)

      ~F"""
      <div class="cart-view">
        <h2>Your Cart</h2>
        {if cart == :disconnected do}
          <p>Loading...</p>
        {else}
          <ul>
            {for item <- cart.items do}
              <li class="cart-item" id={"cart-item-#{item.id}"}>
                {item.name} × {item.quantity} — {div(item.price_cents * item.quantity, 100)} USD
                <button class="remove" on_click={fn -> Cart.Server.remove_item(server, item.id) end}>Remove</button>
              </li>
            {end}
          </ul>
          <p class="total">
            Total: {div(cart.total_cents, 100)} USD
          </p>
        {end}
      </div>
      """
    end
  end
end
