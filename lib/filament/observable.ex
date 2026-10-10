defmodule Filament.Observable do
  @moduledoc """
  Behaviour for observable GenServer processes.

  A GenServer that `use`s `Filament.Observable.GenServer` automatically satisfies
  this behaviour. Implement the optional callbacks to customise the value seen
  by subscribers and to react to teardown.
  """

  @doc """
  Called when a new subscriber registers.

  Return `{:ok, initial_value, new_state}` to accept. `initial_value` is the
  raw value passed to the subscriber's projection function. The default
  accepts with `c:handle_current/1`'s value. Return
  `{:error, reason, new_state}` to reject; the subscriber then reads
  `:disconnected`.

  Runs once per subscriber identity. Subscribing again with the same identity
  refreshes the subscription, as after a full mailbox, without calling this
  or `c:handle_unsubscribe/2`.
  """
  @callback handle_subscribe(
              subscriber :: term(),
              state :: term()
            ) ::
              {:ok, initial_value :: term(), new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}

  @doc """
  Called once when a subscription ends: the subscriber unsubscribed or its
  owner process exited.
  """
  @callback handle_unsubscribe(subscriber :: term(), state :: term()) ::
              {:ok, new_state :: term()}

  @doc """
  The current raw value, for subscribes, `Filament.Cell.current/2` and
  refreshes. Defaults to the whole state. A `c:handle_subscribe/2` that
  accepts with another value must agree with this one.
  """
  @callback handle_current(state :: term()) :: {:ok, value :: term(), new_state :: term()}

  @doc """
  The GenServer timeout Filament's own handlers return with: subscribe,
  unsubscribe and current-value calls, and a subscriber's `:DOWN`.

  A server that keeps a timeout (`{:noreply, state, ms}`) returns the
  same one here, from its state, so a subscriber coming or going doesn't
  cancel it. Defaults to `:infinity`: no timeout.
  """
  @callback timeout(state :: term()) :: timeout()

  @optional_callbacks handle_subscribe: 2, handle_unsubscribe: 2, handle_current: 1, timeout: 1
end
