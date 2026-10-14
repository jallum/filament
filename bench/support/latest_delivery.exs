defmodule Filament.Bench.LatestDelivery do
  @moduledoc """
  Experimental latest-value transport, isolated from the production Cell API.

  One batch may be in flight per owner. Writes replace each cell's latest
  projection; acknowledgment advances its delivered snapshot and flushes only
  the newest pending values. Tokens identify batches and generations identify
  cells. Removing the last cell retains an outstanding batch until acknowledged
  or the owner dies, so repeated unsubscribe/subscribe cannot grow the mailbox.
  """
  use GenServer

  def start_link(initial), do: GenServer.start_link(__MODULE__, initial)
  def subscribe(server, key, projection), do: GenServer.call(server, {:subscribe, key, projection})
  def unsubscribe(server, key), do: GenServer.call(server, {:unsubscribe, key})
  def write(server, value), do: GenServer.call(server, {:write, value})
  def acknowledge(server, token), do: GenServer.cast(server, {:acknowledge, self(), token})
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(initial), do: {:ok, %{value: initial, owners: %{}}}

  @impl true
  def handle_call({:subscribe, key, projection}, {pid, _}, state) do
    owner = Map.get_lazy(state.owners, pid, fn -> %{monitor: Process.monitor(pid), cells: %{}, flight: nil} end)
    value = projection.(state.value)
    generation = make_ref()
    cell = %{projection: projection, generation: generation, latest: value, delivered: value}
    owner = %{owner | cells: Map.put(owner.cells, key, cell)}
    {:reply, {:ok, generation, value}, %{state | owners: Map.put(state.owners, pid, owner)}}
  end

  def handle_call({:unsubscribe, key}, {pid, _}, state) do
    owners =
      case Map.fetch(state.owners, pid) do
        {:ok, owner} -> retain_owner(state.owners, pid, %{owner | cells: Map.delete(owner.cells, key)})
        :error -> state.owners
      end

    {:reply, :ok, %{state | owners: owners}}
  end

  def handle_call({:write, value}, _from, state) do
    owners =
      Map.new(state.owners, fn {pid, owner} ->
        cells = Map.new(owner.cells, fn {key, cell} -> {key, %{cell | latest: cell.projection.(value)}} end)
        {pid, flush(pid, %{owner | cells: cells})}
      end)

    {:reply, :ok, %{state | value: value, owners: owners}}
  end

  def handle_call(:status, _from, state) do
    owners =
      Map.new(state.owners, fn {pid, owner} ->
        {pid, %{cells: map_size(owner.cells), in_flight: owner.flight != nil}}
      end)

    {:reply, owners, state}
  end

  @impl true
  def handle_cast({:acknowledge, pid, token}, state) do
    owners =
      case Map.get(state.owners, pid) do
        %{flight: %{token: ^token, values: values}} = owner ->
          cells = Map.new(owner.cells, fn {key, cell} -> {key, acknowledge_cell(cell, Map.get(values, key))} end)
          owner = flush(pid, %{owner | cells: cells, flight: nil})
          retain_owner(state.owners, pid, owner)

        _ ->
          state.owners
      end

    {:noreply, %{state | owners: owners}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    owners =
      case Map.get(state.owners, pid) do
        %{monitor: ^ref} -> Map.delete(state.owners, pid)
        _ -> state.owners
      end

    {:noreply, %{state | owners: owners}}
  end

  defp acknowledge_cell(%{generation: generation} = cell, {generation, value}), do: %{cell | delivered: value}
  defp acknowledge_cell(cell, _old_generation), do: cell

  defp flush(_pid, %{flight: flight} = owner) when flight != nil, do: owner

  defp flush(pid, owner) do
    values =
      Map.new(for {key, cell} <- owner.cells, cell.latest !== cell.delivered, do: {key, {cell.generation, cell.latest}})

    if map_size(values) == 0 do
      owner
    else
      token = make_ref()
      send(pid, {:latest_delivery, self(), token, values})
      %{owner | flight: %{token: token, values: values}}
    end
  end

  defp retain_owner(owners, pid, %{cells: cells, flight: nil} = owner) when map_size(cells) == 0 do
    Process.demonitor(owner.monitor, [:flush])
    Map.delete(owners, pid)
  end

  defp retain_owner(owners, pid, owner), do: Map.put(owners, pid, owner)
end
