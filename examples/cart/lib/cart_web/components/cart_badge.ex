defmodule CartWeb.Components.CartBadge do
  use Filament.Component


  # server prop: which Cart.Server to subscribe to (pid or registered name).
  # Defaults to Cart.Server for production; tests pass a pid for isolation.
  defcomponent do
    prop(:server, :any, default: Cart.Server)

    def render(%{server: server}) do
      count_projection = fn state -> Cart.State.item_count(state) end
      count = use_observable(server, nil, project: count_projection)

      ~F"""
      <span class="cart-badge" data-count={count}>
        {if count == 0, do: "", else: "#{count}"}
      </span>
      """
    end
  end
end
