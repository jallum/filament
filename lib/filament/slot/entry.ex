defmodule Filament.Slot.Entry do
  @moduledoc false

  @enforce_keys [:render_fn]
  defstruct [:render_fn, attrs: %{}]

  @type t :: %__MODULE__{
          render_fn: (-> Filament.VNode.t()),
          attrs: map()
        }
end
