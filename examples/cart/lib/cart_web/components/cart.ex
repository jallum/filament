defmodule CartWeb.Components.Cart do
  @moduledoc false
  use Filament.Component

  alias CartWeb.Components.CartBadge
  alias CartWeb.Components.CartItems

  defcomponent do
    prop(:session_id, :string, required: true)

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

    def render(%{session_id: session_id}) do
      source =
        use_source(fn ->
          {Filament.Observable.GenServer, Cart.Server.ensure_started(session_id)}
        end)

      server =
        case source do
          {Filament.Observable.GenServer, pid} -> pid
          _ -> nil
        end

      ~F"""
      <div class="page">
        <header class="page-header">
          <h1>Shopping Demo</h1>
          <CartBadge source={source} />
        </header>

        <section class="products">
          {for p <- products() do}
            <div class="product-card">
              <div class="product-name">{p.name}</div>
              <div class="product-price">{format_price(p.price_cents)}</div>
              <button class="btn-add" on_click={fn ->
                if server do
                  Cart.Server.add_item(
                    server,
                    %Cart.Item{id: p.id, name: p.name, price_cents: p.price_cents}
                  )
                end
              end}>Add to Cart</button>
            </div>
          {end}
        </section>

        <CartItems source={source} />
      </div>
      """
    end
  end
end
