defmodule Filament.Observable.Subscriber do
  @moduledoc false

  @enforce_keys [:pid, :request]
  defstruct [
    :pid,
    :request,
    ref: nil,
    projections: %{}
  ]

  @type projection_key :: {fiber_id :: term(), slot_index :: non_neg_integer()}
  @type projection :: {project :: (term() -> term()), last_projected :: term() | :unset}

  @type t :: %__MODULE__{
          pid: pid(),
          request: term(),
          ref: reference() | nil,
          projections: %{projection_key() => projection()}
        }
end
