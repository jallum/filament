defmodule CartWeb.CartLive do
  use Filament.LiveView

  def mount(params, session, socket) do
    socket = Phoenix.Component.assign(socket, :server, Cart.Server)
    super(params, session, socket)
  end

  def root_component, do: CartWeb.Components.CartPage.CartPage
end
