defmodule CartWeb.Components.CartBadge do
  use Filament.Component

  defcomponent do
    prop(:server, :any, default: Cart.Server)

    def render(%{server: server}) do
      count = use_observable(server, project: &Cart.State.item_count/1, disconnected: 0)

      ~F"""
      <span class="cart-badge" data-count={count}>
        {if count > 0, do: count, else: ""}
      </span>
      """
    end
  end
end
