defmodule Cart.Server do
  use Filament.Observable.GenServer

  # Public API
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %Cart.State{}, name: name)
  end

  def add_item(server \\ __MODULE__, %Cart.Item{} = item) do
    GenServer.call(server, {:add_item, item})
  end

  def remove_item(server \\ __MODULE__, item_id) when is_binary(item_id) do
    GenServer.call(server, {:remove_item, item_id})
  end

  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
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

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
end
