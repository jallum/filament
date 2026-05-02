defmodule CartWeb.Components.CartBadge do
  use Filament.Component

  import Filament.Hooks

  # server prop: which Cart.Server to subscribe to (pid or registered name).
  # Defaults to Cart.Server for production; tests pass a pid for isolation.
  defcomponent do
    prop(:server, :any, default: Cart.Server)

    def render(%{server: server} = assigns) do
      # Projection: extract only the count. CartBadge will only re-render when
      # the count changes, not when item names or prices change.
      count_projection = fn state -> Cart.State.item_count(state) end

      # use_observable/3 signature (from Track D):
      #   use_observable(server, request \\ nil, opts \\ [])
      # Opts: project: fn(state) -> projected_value end
      count = use_observable(server, nil, project: count_projection)

      assigns =
        Map.merge(assigns, %{
          count: count
        })

      ~F"""
      <span class="cart-badge" data-count={@count}>
        <%= if @count == 0, do: "", else: "#{@count}" %>
      </span>
      """
    end
  end
end
