defmodule Inventory.Server do
  use Filament.Hold.GenServer

  # State: %{item_id => %Inventory.Item{}}
  @type state :: %{String.t() => Inventory.Item.t()}

  def start_link(opts \\ []) do
    initial_items = Keyword.get(opts, :items, [])
    gen_opts = case Keyword.fetch(opts, :name) do
      {:ok, name} -> [name: name]
      :error -> []
    end
    GenServer.start_link(__MODULE__, initial_items, gen_opts)
  end

  def list_items(server) do
    GenServer.call(server, :list_items)
  end

  def get_item(server, item_id) do
    GenServer.call(server, {:get_item, item_id})
  end

  @impl GenServer
  def init(items) do
    state = Map.new(items, fn item -> {item.id, item} end)
    {:ok, state}
  end

  @impl Filament.Hold
  def handle_acquire(item_id, qty, _holder_pid, state) do
    case Map.get(state, item_id) do
      nil ->
        {:error, :not_found, state}

      %{available: available} when available < qty ->
        {:error, :insufficient, state}

      item ->
        {:ok, Map.put(state, item_id, %{item | available: item.available - qty})}
    end
  end

  @impl Filament.Hold
  def handle_release(item_id, qty, _holder_pid, state) do
    case Map.get(state, item_id) do
      nil -> {:ok, state}
      item -> {:ok, Map.put(state, item_id, %{item | available: item.available + qty})}
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
