defmodule Cart.Item do
  @moduledoc false
  @enforce_keys [:id, :name, :price_cents]
  defstruct [:id, :name, :price_cents, quantity: 1]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          price_cents: non_neg_integer(),
          quantity: pos_integer()
        }
end
