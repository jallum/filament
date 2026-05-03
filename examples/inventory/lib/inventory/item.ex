defmodule Inventory.Item do
  @moduledoc false
  @enforce_keys [:id, :name]
  defstruct [:id, :name, available: 1]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          available: non_neg_integer()
        }
end
