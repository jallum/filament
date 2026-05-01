defmodule Filament.Observable.Subscriber do
  @moduledoc false

  @enforce_keys [:pid, :fiber_id, :slot_index, :project]
  defstruct [
    :pid,
    :fiber_id,
    :slot_index,
    :project,
    ref: nil,
    last_projected: :unset
  ]

  @type t :: %__MODULE__{
          pid: pid(),
          fiber_id: term(),
          slot_index: non_neg_integer(),
          project: (state :: term() -> term()),
          ref: reference() | nil,
          last_projected: term() | :unset
        }
end
