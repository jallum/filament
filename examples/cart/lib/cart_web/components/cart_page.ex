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

    def render(assigns) do
      server = Map.get(assigns, :server)

      # Projection: count-only — mirrors what CartBadge would observe.
      count = Hooks.use_observable(server, nil, project: &Cart.State.item_count/1)

      # Full-state subscription — mirrors what CartView would observe.
      cart = Hooks.use_observable(server)

      items_html =
        case cart do
          :uninitialized ->
            ["<li>Loading...</li>"]

          %Cart.State{items: items} ->
            Enum.map(items, fn item ->
              [
                "<li class=\"cart-item\" id=\"cart-item-",
                item.id,
                "\">",
                Phoenix.HTML.Engine.encode_to_iodata!(item.name),
                " \xc3\x97 ",
                Integer.to_string(item.quantity),
                " \xe2\x80\x94 $",
                Integer.to_string(div(item.price_cents * item.quantity, 100)),
                ".",
                String.pad_leading(Integer.to_string(rem(item.price_cents * item.quantity, 100)), 2, "0"),
                "<button class=\"remove\" phx-click=\"remove_item:",
                item.id,
                "\">Remove</button>",
                "</li>"
              ]
            end)
        end

      total_str =
        case cart do
          :uninitialized -> "0.00"
          %Cart.State{total_cents: t} ->
            "$#{div(t, 100)}.#{String.pad_leading(Integer.to_string(rem(t, 100)), 2, "0")}"
        end

      products_html =
        Enum.map(products(), fn p ->
          [
            "<button phx-click=\"add_item:",
            p.id,
            "\">Add ",
            Phoenix.HTML.Engine.encode_to_iodata!(p.name),
            " ($",
            Integer.to_string(div(p.price_cents, 100)),
            ".",
            String.pad_leading(Integer.to_string(rem(p.price_cents, 100)), 2, "0"),
            ")</button>"
          ]
        end)

      assigns =
        Map.merge(assigns, %{
          count: count,
          cart: cart,
          items_html: items_html,
          total_str: total_str,
          products_html: products_html
        })

      ~F"""
      <div>
        <h1>
          Shopping Demo
          <span class="cart-badge" data-count={@count} data-testid="cart-count">
            {@count}
          </span>
        </h1>

        <div class="products" data-testid="products">
          <%= Phoenix.HTML.raw(@products_html) %>
        </div>

        <div class="cart-view" data-testid="cart-view">
          <h2>Your Cart</h2>
          <ul class="cart-items" data-testid="cart-items">
            <%= Phoenix.HTML.raw(@items_html) %>
          </ul>
          <p class="total" data-testid="cart-total">Total: {@total_str}</p>
        </div>
      </div>
      """
    end

    def handle_event("add_item:" <> id, _params, props) do
      server = Map.get(props, :server)
      product = Enum.find(products(), &(&1.id == id))

      if product do
        item = %Cart.Item{
          id: product.id,
          name: product.name,
          price_cents: product.price_cents
        }
        Cart.Server.add_item(server, item)
      end

      {props, :ok}
    end

    def handle_event("remove_item:" <> id, _params, props) do
      server = Map.get(props, :server)
      Cart.Server.remove_item(server, id)
      {props, :ok}
    end
  end
end
