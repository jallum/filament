defmodule Cart.Server do
  @moduledoc false
  use Filament.Observable.GenServer

  def via_registry(session_id), do: {:via, Registry, {Cart.Registry, session_id}}

  def ensure_started(session_id) do
    case DynamicSupervisor.start_child(Cart.DynamicSupervisor, {__MODULE__, [name: via_registry(session_id)]}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # Public API
  def start_link(opts \\ []) do
    {name, _} = Keyword.pop(opts, :name, nil)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, %Cart.State{}, gen_opts)
  end

  def add_item(server, %Cart.Item{} = item) do
    GenServer.call(server, {:add_item, item})
  end

  def remove_item(server, item_id) when is_binary(item_id) do
    GenServer.call(server, {:remove_item, item_id})
  end

  # GenServer callbacks

  @impl GenServer
  def init(initial_state) do
    {:ok, initial_state}
  end

  # Observable callback — called when a new subscriber joins.
  # Returns {:ok, initial_projected_value, new_server_state}.
  @impl Filament.Observable
  def handle_subscribe(_request, _subscriber, state) do
    {:ok, state, state}
  end

  @impl GenServer
  def handle_call({:add_item, item}, _from, state) do
    new_state = Cart.State.add_item(state, item)
    notify_observers(new_state)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:remove_item, item_id}, _from, state) do
    new_state = Cart.State.remove_item(state, item_id)
    notify_observers(new_state)
    {:reply, :ok, new_state}
  end
end
