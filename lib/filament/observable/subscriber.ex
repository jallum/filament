defmodule Filament.Observable.Subscriber do
  @moduledoc false

  @enforce_keys [:pid]
  defstruct [
    :pid,
    ref: nil,
    last_raw: :unset,
    proj_keys: %{}
  ]

  @type projection_key :: {fiber_id :: term(), slot_index :: non_neg_integer()}

  @type t :: %__MODULE__{
          pid: pid(),
          ref: reference() | nil,
          last_raw: term(),
          proj_keys: %{projection_key() => true}
        }
end
