defmodule CartWeb.Components.CartBadge do
  @moduledoc false
  use Filament.Component

  defcomponent do
    prop(:server, :any, default: nil)

    def render(%{server: server}) do
      count =
        use_observable(server, fn
          :disconnected -> 0
          s -> Cart.State.item_count(s)
        end)

      ~F"""
      <span class="cart-badge" data-count={count}>
        {if count > 0, do: count, else: ""}
      </span>
      """
    end
  end
end
