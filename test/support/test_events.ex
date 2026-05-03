defmodule Filament.TestEvents do
  @moduledoc false
  import Filament.Event

  defevent TestPurchased do
    field(:item_id, :string, required: true)
    field(:quantity, :integer, default: 1)
    field(:note, :string)
  end
end
