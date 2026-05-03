defmodule CartWeb.Components.CartBadge do
  use Filament.Component

  defcomponent do
    prop(:session_id, :string, default: nil)
    prop(:server, :any, default: nil)

    def render(%{session_id: session_id, server: server}) do
      server = server || Cart.Server.ensure_started(session_id)
      count = use_observable(server, project: &Cart.State.item_count/1, disconnected: 0)

      ~F"""
      <span class="cart-badge" data-count={count}>
        {if count > 0, do: count, else: ""}
      </span>
      """
    end
  end
end
