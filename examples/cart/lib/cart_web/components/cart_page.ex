defmodule CartWeb.Components.CartPage do
  @moduledoc """
  Root component for the cart demo.

  Demonstrates two use_observable subscriptions to the same Cart.Server:
  - count_projection (used for the badge): re-renders only when item count changes
  - full state (used for the cart view): re-renders on any mutation
  """
  use Filament.Component

  alias Filament.Hooks

  defcomponent do
    prop(:server, :any, default: Cart.Server)

    defp products do
      [
        %{id: "apple", name: "Apple", price_cents: 99},
        %{id: "banana", name: "Banana", price_cents: 149},
        %{id: "cherry", name: "Cherry (bag)", price_cents: 299}
      ]
    end

    def render(%{server: server}) do
      count = Hooks.use_observable(server, nil, project: &Cart.State.item_count/1)
      cart = Hooks.use_observable(server)

      items = case cart do
        :uninitialized -> []
        %Cart.State{items: items} -> items
      end

      total_str = case cart do
        :uninitialized -> "$0.00"
        %Cart.State{total_cents: t} ->
          "$#{div(t, 100)}.#{String.pad_leading(Integer.to_string(rem(t, 100)), 2, "0")}"
      end

      ~F"""
      <div>
        <h1>
          Shopping Demo
          <span class="cart-badge" data-count={count} data-testid="cart-count">
            {count}
          </span>
        </h1>

        <div class="products" data-testid="products">
          {for p <- products() do}
            <button on_click={fn ->
              item = %Cart.Item{id: p.id, name: p.name, price_cents: p.price_cents}
              Cart.Server.add_item(server, item)
            end}>
              Add {p.name} ($#{div(p.price_cents, 100)}.{String.pad_leading(Integer.to_string(rem(p.price_cents, 100)), 2, "0")})
            </button>
          {end}
        </div>

        <div class="cart-view" data-testid="cart-view">
          <h2>Your Cart</h2>
          <ul class="cart-items" data-testid="cart-items">
            {if cart == :uninitialized do}
              <li>Loading...</li>
            {else}
              {for item <- items do}
                <li class="cart-item" id={"cart-item-#{item.id}"}>
                  {item.name} × {item.quantity}
                  <button class="remove" on_click={fn -> Cart.Server.remove_item(server, item.id) end}>Remove</button>
                </li>
              {end}
            {end}
          </ul>
          <p class="total" data-testid="cart-total">Total: {total_str}</p>
        </div>
      </div>
      """
    end
  end
end
