defmodule Cart.State do
  @moduledoc false
  defstruct items: [], total_cents: 0

  @type t :: %__MODULE__{
          items: [Cart.Item.t()],
          total_cents: non_neg_integer()
        }

  def add_item(%__MODULE__{} = state, %Cart.Item{} = item) do
    # If item already in cart, increment quantity; otherwise append.
    case Enum.find_index(state.items, &(&1.id == item.id)) do
      nil ->
        items = state.items ++ [item]
        total = state.total_cents + item.price_cents * item.quantity
        %{state | items: items, total_cents: total}

      idx ->
        existing = Enum.at(state.items, idx)
        updated = %{existing | quantity: existing.quantity + 1}
        items = List.replace_at(state.items, idx, updated)
        %{state | items: items, total_cents: state.total_cents + item.price_cents}
    end
  end

  def remove_item(%__MODULE__{} = state, item_id) when is_binary(item_id) do
    case Enum.find(state.items, &(&1.id == item_id)) do
      nil ->
        state

      removed ->
        items = Enum.reject(state.items, &(&1.id == item_id))
        total = state.total_cents - removed.price_cents * removed.quantity
        %{state | items: items, total_cents: max(0, total)}
    end
  end

  def item_count(%__MODULE__{items: items}) do
    Enum.sum(Enum.map(items, & &1.quantity))
  end
end
