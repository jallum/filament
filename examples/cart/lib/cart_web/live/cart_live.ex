defmodule CartWeb.CartLive do
  use Filament.LiveView

  def mount(params, session, socket) do
    socket = assign(socket, :session_id, socket.id)
    super(params, session, socket)
  end

  def root_component, do: CartWeb.Components.Cart
end
