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

  @doc "Add an item using a session ID or an already resolved server."
  def add_item(cart_ref, %Cart.Item{} = item) do
    Server.add_item(command_server(cart_ref), item)
  end

  @doc "Remove an item using a session ID or an already resolved server."
  def remove_item(cart_ref, item_id) when is_binary(item_id) do
    Server.remove_item(command_server(cart_ref), item_id)
  end

  defp source_for(session_id) when is_binary(session_id), do: Server.cell(session_id)
  defp source_for(server), do: Source.new(Transport, server)

  defp source_for_value(nil), do: nil
  defp source_for_value(cart), do: Source.new(Transport, cart)

  defp command_server(session_id) when is_binary(session_id), do: Server.via_registry(session_id)
  defp command_server(server), do: server
end
