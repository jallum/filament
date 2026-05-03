defmodule Filament.Hold do
  @moduledoc """
  Behaviour for GenServers that grant quantity-based resource holds to Filament components.

  A hold is acquired by a LiveView process on behalf of a fiber. If the LiveView
  process terminates for any reason (disconnect, crash), all holds are automatically
  released via the observable subscription lifecycle — no cleanup message is required.

  Use `Filament.Hold.GenServer` to implement the server side with minimal boilerplate.
  """

  @doc """
  Called when a client requests to hold `qty` units of `item_id`.
  Return `{:ok, new_state}` to grant or `{:error, reason, state}` to deny.
  """
  @callback handle_acquire(
              item_id :: term(),
              qty :: pos_integer(),
              holder_pid :: pid(),
              state :: term()
            ) ::
              {:ok, new_state :: term()}
              | {:error, reason :: term(), state :: term()}

  @doc """
  Called when a holder releases `qty` units of `item_id`, either explicitly
  or because their process terminated.
  """
  @callback handle_release(
              item_id :: term(),
              qty :: pos_integer(),
              holder_pid :: pid(),
              state :: term()
            ) ::
              {:ok, new_state :: term()}

  @optional_callbacks handle_acquire: 4, handle_release: 4
end
