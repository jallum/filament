defmodule Inventory.Server do
  @moduledoc false
  use Filament.Observable.GenServer

  # State: items map + per-pid hold tracking
  # holds: %{pid() => %{item_id => qty}}
  defstruct items: %{}, holds: %{}

  def start_link(opts \\ []) do
    initial_items = Keyword.get(opts, :items, [])

    gen_opts =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> [name: name]
        :error -> []
      end

    GenServer.start_link(__MODULE__, initial_items, gen_opts)
  end

  def list_items(server), do: GenServer.call(server, :list_items)
  def get_item(server, item_id), do: GenServer.call(server, {:get_item, item_id})

  @impl GenServer
  def init(items) do
    {:ok, %__MODULE__{items: Map.new(items, &{&1.id, &1})}}
  end

  # Return the items map as the observable value so subscribers' project fns
  # (e.g. `&Map.get(&1, item_id)`) continue to work against a plain map.
  @impl Filament.Observable
  def handle_subscribe(_request, _subscriber, state) do
    {:ok, state.items, state}
  end

  # Automatic hold release when a subscriber's LiveView process terminates.
  @impl Filament.Observable
  def handle_unsubscribe(subscriber, state) do
    case Map.pop(state.holds, subscriber.pid) do
      {nil, _} ->
        {:ok, state}

      {holder_holds, new_holds} ->
        new_items =
          Enum.reduce(holder_holds, state.items, fn {item_id, qty}, acc ->
            Map.update(acc, item_id, nil, &%{&1 | available: &1.available + qty})
          end)

        new_state = %{state | items: new_items, holds: new_holds}
        notify_observers(new_state.items)
        {:ok, new_state}
    end
  end

  @impl GenServer
  def handle_call(:list_items, _from, state) do
    {:reply, Map.values(state.items), state}
  end

  def handle_call({:get_item, item_id}, _from, state) do
    {:reply, Map.get(state.items, item_id), state}
  end

  def handle_call({:filament_hold, item_id, qty, holder_pid}, _from, state) do
    case Map.get(state.items, item_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{available: available} when available < qty ->
        {:reply, {:error, :insufficient}, state}

      item ->
        new_items = Map.put(state.items, item_id, %{item | available: item.available - qty})
        holder_holds = Map.get(state.holds, holder_pid, %{})
        new_holds = Map.put(state.holds, holder_pid, Map.update(holder_holds, item_id, qty, &(&1 + qty)))
        new_state = %{state | items: new_items, holds: new_holds}
        notify_observers(new_state.items)
        {:reply, :ok, new_state}
    end
  end

  @impl GenServer
  def handle_cast({:filament_release_qty, item_id, qty, holder_pid}, state) do
    holder_holds = Map.get(state.holds, holder_pid, %{})
    current_qty = Map.get(holder_holds, item_id, 0)
    actual_qty = min(qty, current_qty)

    if actual_qty > 0 do
      new_holder_holds =
        if current_qty - actual_qty <= 0,
          do: Map.delete(holder_holds, item_id),
          else: Map.put(holder_holds, item_id, current_qty - actual_qty)

      new_items =
        Map.update(state.items, item_id, nil, &%{&1 | available: &1.available + actual_qty})

      new_state = %{state | items: new_items, holds: Map.put(state.holds, holder_pid, new_holder_holds)}
      notify_observers(new_state.items)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end
end
