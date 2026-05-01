defmodule Filament.Hold do
  @moduledoc """
  Behaviour for GenServers that grant resource holds to client processes.

  A hold is acquired by a LiveView process on behalf of a fiber. If the LiveView
  process terminates for any reason (disconnect, crash), the hold is automatically
  released via BEAM :DOWN monitoring — no cleanup message is required from the client.

  Explicit release also occurs when the fiber unmounts cleanly.

  Use `Filament.Hold.GenServer` to implement the server side with minimal boilerplate.
  """

  @doc """
  Called when a client requests a hold. Return `{:ok, token, new_state}` to grant.
  `token` is an opaque value returned to the caller via `use_hold/3`.
  Return `{:error, reason, new_state}` to deny.
  """
  @callback handle_acquire(
              request :: term(),
              holder :: pid(),
              state :: term()
            ) ::
              {:ok, token :: term(), new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}

  @doc """
  Called when a holder explicitly releases a hold or its process terminates (:DOWN).
  `token` is the opaque value returned by `handle_acquire/3`.
  """
  @callback handle_release(token :: term(), holder :: pid(), state :: term()) ::
              {:ok, new_state :: term()}

  @optional_callbacks handle_acquire: 3, handle_release: 3

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Acquire a hold from `server`. Called by `use_hold/3`. Do not call directly.
  """
  @spec acquire(server :: GenServer.server(), request :: term(), holder :: pid()) ::
          {:ok, token :: term()} | {:error, reason :: term()}
  def acquire(server, request, holder) do
    GenServer.call(server, {:filament_acquire, request, holder})
  end

  @doc """
  Release a hold from `server`. Called on fiber unmount. Do not call directly.
  """
  @spec release(server :: GenServer.server(), holder :: pid()) :: :ok
  def release(server, holder) do
    GenServer.cast(server, {:filament_release, holder})
  end
end
