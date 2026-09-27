defmodule CartWeb.Hooks do
  @moduledoc "Domain hooks for the shopping cart example."

  import Filament.Hooks, only: [use_source: 2, use_value: 2]

  alias Cart.Server
  alias Filament.Observable.GenServer, as: Transport
  alias Filament.Source

  @doc "Find or start a session cart; also accepts a server ref for isolated tests."
  def use_cart(cart_ref) do
    case use_source(fn -> source_for(cart_ref) end, cart_ref) do
      nil -> nil
      source -> source.data
    end
  end

  @doc "Read the item count, including a safe static-render value."
  def use_cart_count(cart_ref) do
    cart = use_cart(cart_ref)

    use_value(source_for_value(cart), fn
      :disconnected -> 0
      state -> Cart.State.item_count(state)
    end)
  end

  @doc "Read the cart state, or nil before connecting."
  def use_cart_state(cart_ref) do
    cart = use_cart(cart_ref)

    use_value(source_for_value(cart), fn
      :disconnected -> nil
      state -> state
    end)
  end

  defp source_for(session_id) when is_binary(session_id), do: Server.cell(session_id)
  defp source_for(server), do: Source.new(Transport, server)

  defp source_for_value(nil), do: nil
  defp source_for_value(cart), do: Source.new(Transport, cart)
end
