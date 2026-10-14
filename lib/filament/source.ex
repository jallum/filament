defmodule Filament.Source do
  @moduledoc """
  The value users hold when they call `use_source/1`.

  Filament splits "what users carry around" from "how the runtime
  dispatches" into two related names:

    * **`Filament.Cell`** — the *behaviour* a transport implements
      (`subscribe/3`, `unsubscribe/2`, `current/2`).
    * **`Filament.Source`** — the *struct* application code holds. Carries
      the transport module to dispatch through and the data the transport
      needs (a server reference, a struct, anything).

  Application code accesses the underlying server via `source.data`:

      source = use_source(fn -> Cart.Server.cell(session_id) end)
      cart   = use_value(source, fn :disconnected -> nil; s -> s end)
      on_click = fn -> Cart.Server.add_item(source.data, item) end

  No unwrap helper, no destructure. The struct also leaves room to
  carry forward-compatible metadata (debug names, transport options)
  without breaking pattern matchers on existing fields.
  """

  @enforce_keys [:transport, :data]
  defstruct [:transport, :data]

  @type transport :: module()
  @type data :: term()
  @type t :: %__MODULE__{transport: transport(), data: data()}

  @doc """
  Build a source. Most application code constructs one via the per-server
  `cell/1` constructor that `use Filament.Observable.GenServer` injects;
  use this when implementing a fresh transport.
  """
  @spec new(transport(), data()) :: t()
  def new(transport, data) when is_atom(transport) do
    %__MODULE__{transport: transport, data: data}
  end
end
