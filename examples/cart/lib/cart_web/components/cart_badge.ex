defmodule CartWeb.Components.CartBadge do
  @moduledoc false
  use Filament.Component

  defcomponent do
    prop(:source, :any, default: nil)

    def render(%{source: source}) do
      count =
        use_value(source, fn
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
