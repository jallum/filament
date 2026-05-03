defmodule Collaboration.DocumentServer do
  @moduledoc """
  Document Server implementing both Observable and hold management.

  DESIGN NOTE: This server combines Filament.Observable.GenServer with custom
  hold management for document locks. The Observable macro handles subscriber
  tracking and presence counting, while we manually manage the document lock
  state. When subscribers holding the lock disconnect, the :DOWN handler releases
  the lock automatically.
  """
  use Filament.Observable.GenServer

  defstruct [:doc_id, content: "", lock_holder: nil, presence: 0]

  @type t :: %__MODULE__{
          doc_id: String.t(),
          content: String.t(),
          lock_holder: pid() | nil,
          presence: non_neg_integer()
        }

  def start_link(opts \\ []) do
    doc_id = Keyword.fetch!(opts, :doc_id)
    name = Keyword.get(opts, :name, {:via, Registry, {Collaboration.Registry, doc_id}})
    GenServer.start_link(__MODULE__, doc_id, name: name)
  end

  # Public API

  def acquire_lock(server, holder_pid) do
    GenServer.call(server, {:acquire_lock, holder_pid})
  end

  def release_lock(server, holder_pid) do
    GenServer.call(server, {:release_lock, holder_pid})
  end

  # GenServer callbacks

  @impl GenServer
  def init(doc_id) do
    {:ok, %__MODULE__{doc_id: doc_id}}
  end

  # Observable callback — called when a subscriber joins.
  @impl Filament.Observable
  def handle_subscribe(_request, _subscriber, state) do
    new_state = %{state | presence: state.presence + 1}
    initial_view = observable_view(new_state)
    notify_observers(initial_view)
    {:ok, initial_view, new_state}
  end

  # Handle unsubscribe when a subscriber process dies.
  # The first arg is a %Filament.Observable.Subscriber{} struct — extract .pid for lock comparison.
  @impl Filament.Observable
  def handle_unsubscribe(subscriber, state) do
    new_state =
      state
      |> maybe_release_lock(subscriber.pid)
      |> decrement_presence()

    notify_observers(observable_view(new_state))
    {:ok, new_state}
  end

  @impl GenServer
  def handle_call({:acquire_lock, holder_pid}, _from, state) do
    case state.lock_holder do
      nil ->
        new_state = %{state | lock_holder: holder_pid}
        notify_observers(observable_view(new_state))
        {:reply, {:ok, :lock_token}, new_state}

      _ ->
        {:reply, {:error, :locked}, state}
    end
  end

  @impl GenServer
  def handle_call({:release_lock, holder_pid}, _from, state) do
    if state.lock_holder == holder_pid do
      new_state = %{state | lock_holder: nil}
      notify_observers(observable_view(new_state))
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_holder}, state}
    end
  end

  # Private helpers

  defp observable_view(%__MODULE__{} = state) do
    %{
      locked: state.lock_holder != nil,
      lock_holder: state.lock_holder,
      presence: state.presence
    }
  end

  defp maybe_release_lock(state, pid) do
    if state.lock_holder == pid do
      %{state | lock_holder: nil}
    else
      state
    end
  end

  defp decrement_presence(state) do
    %{state | presence: max(0, state.presence - 1)}
  end

  def via_registry(doc_id) do
    {:via, Registry, {Collaboration.Registry, doc_id}}
  end
end
