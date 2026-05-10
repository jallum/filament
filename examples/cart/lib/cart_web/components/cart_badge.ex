defmodule CartWeb.Components.CartBadge do
  @moduledoc false
  use Filament.Component

  defcomponent do
    prop(:cell, :any, default: nil)

    def render(%{cell: cell}) do
      count =
        use_cell(cell, fn
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
