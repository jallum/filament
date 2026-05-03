defmodule CartWeb.Components.CartPage do
  use Filament.Component

  alias CartWeb.Components.CartBadge
  alias CartWeb.Components.CartView

  defcomponent do
    defp products do
      [
        %{id: "apple", name: "Apple", price_cents: 99},
        %{id: "banana", name: "Banana", price_cents: 149},
        %{id: "cherry", name: "Cherry (bag)", price_cents: 299}
      ]
    end

    defp format_price(cents) do
      "$#{div(cents, 100)}.#{String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")}"
    end

    def render(_assigns) do
      ~F"""
      <div class="page">
        <header class="page-header">
          <h1>Shopping Demo</h1>
          <CartBadge />
        </header>

        <section class="products">
          {for p <- products() do}
            <div class="product-card">
              <div class="product-name">{p.name}</div>
              <div class="product-price">{format_price(p.price_cents)}</div>
              <button class="btn-add" on_click={fn ->
                Cart.Server.add_item(%Cart.Item{id: p.id, name: p.name, price_cents: p.price_cents})
              end}>Add to Cart</button>
            </div>
          {end}
        </section>

        <CartView />
      </div>
      """
    end
  end
end
