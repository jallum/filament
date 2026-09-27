defmodule Collaboration.DocumentServer do
  @moduledoc """
  Document Server implementing both Observable and hold management.

  DESIGN NOTE: This server combines Filament.Observable.GenServer with custom
  hold management for document locks. The Observable macro monitors reader
  subscriptions; this module groups those readers by owner for presence and
  releases a lock when its owner's last reader leaves.
  """
  use Filament.Observable.GenServer

  defstruct [:doc_id, content: "", lock_holder: nil, presence: 0, owners: %{}]

  @type t :: %__MODULE__{
          doc_id: String.t(),
          content: String.t(),
          lock_holder: pid() | nil,
          presence: non_neg_integer(),
          owners: %{optional(pid()) => pos_integer()}
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

  # Multiple read hooks from one LiveView still represent one viewer.
  @impl Filament.Observable
  def handle_subscribe(subscriber, state) do
    pid = subscriber_owner(subscriber)
    owners = Map.update(state.owners, pid, 1, &(&1 + 1))
    new_state = %{state | owners: owners, presence: map_size(owners)}
    initial_view = observable_view(new_state)
    if new_state.presence != state.presence, do: notify_observers(initial_view)
    {:ok, initial_view, new_state}
  end

  # Release a viewer's lock only when its last read hook leaves.
  @impl Filament.Observable
  def handle_unsubscribe(subscriber, state) do
    pid = subscriber_owner(subscriber)

    new_state =
      case Map.get(state.owners, pid) do
        nil ->
          state

        1 ->
          owners = Map.delete(state.owners, pid)
          %{maybe_release_lock(state, pid) | owners: owners, presence: map_size(owners)}

        count ->
          %{state | owners: Map.put(state.owners, pid, count - 1)}
      end

    if observable_view(new_state) != observable_view(state),
      do: notify_observers(observable_view(new_state))

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

  defp subscriber_owner({pid, _, _, _}) when is_pid(pid), do: pid
  defp subscriber_owner({pid, _, _}) when is_pid(pid), do: pid
  defp subscriber_owner(_), do: self()

  def via_registry(doc_id) do
    {:via, Registry, {Collaboration.Registry, doc_id}}
  end

  # Override the default cell/1 from `use Filament.Observable.GenServer`
  # so components can pass a doc_id directly.
  def cell(doc_id) when is_binary(doc_id) do
    Filament.Source.new(Filament.Observable.GenServer, via_registry(doc_id))
  end
end
