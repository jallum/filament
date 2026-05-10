defmodule Filament.Observable do
  @moduledoc """
  Behaviour for observable GenServer processes.

  A GenServer that `use`s `Filament.Observable.GenServer` automatically satisfies
  this behaviour. Implement the optional callbacks to customise the value seen
  by subscribers and to react to teardown.
  """

  @doc """
  Called when a new subscriber registers (and to read the current value).

  Return `{:ok, initial_value, new_state}` to accept. `initial_value` is the
  raw value passed to the subscriber's projection function.
  """
  @callback handle_subscribe(
              subscriber :: term(),
              state :: term()
            ) ::
              {:ok, initial_value :: term(), new_state :: term()}

  @doc """
  Called when a subscriber unsubscribes.
  """
  @callback handle_unsubscribe(subscriber :: term(), state :: term()) ::
              {:ok, new_state :: term()}

  @optional_callbacks handle_subscribe: 2, handle_unsubscribe: 2
end
