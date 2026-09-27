defmodule CartWeb.Components.CartBadge do
  @moduledoc false
  use Filament.Component

  import CartWeb.Hooks, only: [use_cart_count: 1]

  defcomponent do
    prop(:cart, :any, default: nil)

    def render(%{cart: cart}) do
      count = use_cart_count(cart)

      ~F"""
      <span class="cart-badge" data-count={count}>
        {if count > 0, do: count, else: ""}
      </span>
      """
    end
  end
end
