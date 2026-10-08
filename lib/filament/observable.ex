defmodule Filament.Observable do
  @moduledoc """
  Behaviour for observable GenServer processes.

  A GenServer that `use`s `Filament.Observable.GenServer` automatically satisfies
  this behaviour. Implement the optional callbacks to customise subscription
  acceptance and teardown.
  """

  @doc """
  Called when a new subscriber requests a subscription.

  Return `{:ok, initial_value, new_state}` to accept.
  `initial_value` is the raw server state sent back to the subscriber.

  Return `{:error, reason, new_state}` to reject.
  """
  @callback handle_subscribe(
              subscriber :: term(),
              state :: term()
            ) ::
              {:ok, initial_value :: term(), new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}

  @doc """
  Called when a subscriber unsubscribes or its process terminates.
  """
  @callback handle_unsubscribe(subscriber :: term(), state :: term()) ::
              {:ok, new_state :: term()}

  @doc """
  The GenServer timeout Filament's own handlers return with: the
  subscribe call, projection removal, and a subscriber's `:DOWN`.

  A server that keeps a timeout (`{:noreply, state, ms}`) returns the
  same one here, from its state, so a subscriber coming or going doesn't
  cancel it. Defaults to `:infinity`: no timeout.
  """
  @callback timeout(state :: term()) :: timeout()

  @optional_callbacks handle_subscribe: 2, handle_unsubscribe: 2, timeout: 1

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc false
  @spec subscribe(observable :: GenServer.server(), subscriber :: term()) ::
          {:ok, term()} | {:error, term()}
  def subscribe(observable, subscriber) do
    GenServer.call(observable, {:filament_subscribe, subscriber})
  end

  @doc false
  @spec remove_projection(
          observable :: GenServer.server(),
          owner_pid :: pid(),
          fiber_id :: term(),
          slot_index :: non_neg_integer()
        ) :: :ok
  def remove_projection(observable, owner_pid, fiber_id, slot_index) do
    proj_key = {fiber_id, slot_index}
    GenServer.cast(observable, {:filament_remove_projection, owner_pid, proj_key})
  end
end
