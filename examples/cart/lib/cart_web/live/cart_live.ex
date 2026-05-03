defmodule CartWeb.CartLive do
  use Filament.LiveView

  def root_component, do: CartWeb.Components.CartPage
end
