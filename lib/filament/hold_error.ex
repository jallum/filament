defmodule Filament.HoldError do
  @moduledoc """
  Raised by `Filament.Hooks.use_hold/3` when the `Hold.GenServer` denies the request.

  Fields:
    - `:message` — human-readable error string
    - `:server` — the server that rejected the hold
    - `:reason` — the reason returned by `handle_acquire/3` (e.g. `:insufficient`, `:not_found`)
  """
  defexception [:message, :server, :reason]
end
