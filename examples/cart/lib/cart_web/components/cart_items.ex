defmodule CartWeb.Components.CartItems do
  @moduledoc false
  use Filament.Component

  defcomponent do
    prop(:session_id, :string, default: nil)
    prop(:server, :any, default: nil)

    defp format_price(cents) do
      "$#{div(cents, 100)}.#{String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")}"
    end

    def render(%{session_id: session_id, server: server}) do
      server = server || Cart.Server.ensure_started(session_id)
      {_server, cart} = use_observable(server, disconnected: nil)

      ~F"""
      <section class="cart-section">
        <h2>Your Cart</h2>
        {if cart == nil do}
          <p class="cart-empty">Connecting…</p>
        {else}
          {if cart.items == [] do}
            <p class="cart-empty">Your cart is empty.</p>
          {else}
            <ul class="cart-items">
              {for item <- cart.items do}
                <li class="cart-item" id={"cart-item-#{item.id}"}>
                  <span class="item-name">{item.name}</span>
                  <span class="item-qty">× {item.quantity}</span>
                  <span class="item-price">{format_price(item.price_cents * item.quantity)}</span>
                  <button class="btn-remove" on_click={fn -> Cart.Server.remove_item(server, item.id) end}>Remove</button>
                </li>
              {end}
            </ul>
          {end}
          <div class="cart-total">Total: {format_price(cart.total_cents)}</div>
        {end}
      </section>
      """
    end
  end
end
