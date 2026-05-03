defmodule Inventory.Server do
  use Filament.Hold.GenServer

  # State: %{item_id => %Inventory.Item{}}
  @type state :: %{String.t() => Inventory.Item.t()}

  def start_link(opts \\ []) do
    initial_items = Keyword.get(opts, :items, [])
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, initial_items, name: name)
  end

  def list_items(server \\ __MODULE__) do
    GenServer.call(server, :list_items)
  end

  def get_item(server \\ __MODULE__, item_id) do
    GenServer.call(server, {:get_item, item_id})
  end

  # GenServer callbacks

  @impl GenServer
  def init(items) do
    state = Map.new(items, fn item -> {item.id, item} end)
    {:ok, state}
  end

  # Hold callbacks — called by the Hold.GenServer macro on acquire/release.
  # request is the item_id passed to use_hold/3.
  # holder_pid is the subscribing fiber's pid.

  @impl Filament.Hold
  def handle_acquire(item_id, _holder_pid, state) do
    case Map.get(state, item_id) do
      nil ->
        {:error, :not_found, state}

      %{available: 0} ->
        {:error, :insufficient, state}

      item ->
        token = {item_id, make_ref()}
        new_item = %{item | available: item.available - 1}
        {:ok, token, Map.put(state, item_id, new_item)}
    end
  end

  # handle_release/3 is called when the holder process dies (:DOWN) or explicitly
  # releases the hold. The token was returned by handle_acquire/3.
  @impl Filament.Hold
  def handle_release({item_id, _ref}, _holder_pid, state) do
    case Map.get(state, item_id) do
      nil ->
        {:ok, state}

      item ->
        new_item = %{item | available: item.available + 1}
        {:ok, Map.put(state, item_id, new_item)}
    end
  end

  @impl GenServer
  def handle_call(:list_items, _from, state) do
    {:reply, Map.values(state), state}
  end

  def handle_call({:get_item, item_id}, _from, state) do
    {:reply, Map.get(state, item_id), state}
  end
end
