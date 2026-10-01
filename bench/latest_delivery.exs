# Run with: ERL_FLAGS='+S 4:4' mix run bench/latest_delivery.exs
Code.require_file("support/latest_delivery.exs", __DIR__)

defmodule Filament.Bench.DeliveryStore do
  @moduledoc false
  use Filament.Observable.GenServer

  def start_link(initial), do: GenServer.start_link(__MODULE__, initial)
  def init(initial), do: {:ok, initial}

  def handle_call({:write, value}, _from, _state) do
    notify_observers(value)
    {:reply, :ok, value}
  end
end

defmodule Filament.Bench.DeliveryComparison do
  @moduledoc false
  alias Filament.Bench.DeliveryStore
  alias Filament.Bench.LatestDelivery

  def run(cells, writes) do
    current = measure(:current, cells, writes)
    latest = measure(:latest, cells, writes)
    %{cells: cells, writes: writes, current: current, latest: latest}
  end

  defp measure(mode, cells, writes) do
    owner = spawn(fn -> owner_loop() end)
    {:ok, server} = start(mode)

    try do
      command(owner, fn ->
        for key <- 1..cells, do: subscribe(mode, server, key)
      end)

      {elapsed, _} =
        :timer.tc(fn ->
          for value <- 1..writes, do: write(mode, server, value)
        end)

      {:messages, queued} = Process.info(owner, :messages)
      recover(mode, owner, server, cells, writes)
      %{write_time_us: elapsed, queued_messages: length(queued)}
    after
      Process.exit(owner, :kill)
      GenServer.stop(server)
    end
  end

  defp start(:current), do: DeliveryStore.start_link(0)
  defp start(:latest), do: LatestDelivery.start_link(0)
  defp write(:current, server, value), do: GenServer.call(server, {:write, value})
  defp write(:latest, server, value), do: LatestDelivery.write(server, value)

  defp subscribe(:current, server, key),
    do: Filament.Observable.GenServer.subscribe(server, {self(), key, 0}, &Function.identity/1)

  defp subscribe(:latest, server, key), do: LatestDelivery.subscribe(server, key, &Function.identity/1)

  defp recover(:current, owner, server, cells, expected) do
    command(owner, fn ->
      # Existing saturation recovery needs a synchronous read for each cell.
      for key <- 1..cells do
        {:ok, ^expected} = subscribe(:current, server, key)
      end
    end)
  end

  defp recover(:latest, owner, server, cells, expected) do
    command(owner, fn ->
      {token, first} = take(server)
      if map_size(first) != cells, do: raise("missing initial cells")
      LatestDelivery.acknowledge(server, token)
      LatestDelivery.status(server)
      {token, final} = take(server)

      if not final_values?(final, cells, expected),
        do: raise("final value lost")

      LatestDelivery.acknowledge(server, token)
      %{cells: ^cells, in_flight: false} = LatestDelivery.status(server)[self()]
    end)
  end

  defp final_values?(values, cells, expected) do
    map_size(values) == cells and Enum.all?(values, fn {_, {_, value}} -> value == expected end)
  end

  defp take(server) do
    receive do
      {:latest_delivery, ^server, token, values} -> {token, values}
    after
      5_000 -> raise("missing delivery")
    end
  end

  defp owner_loop do
    receive do
      {:run, from, ref, function} ->
        send(from, {ref, function.()})
        owner_loop()
    end
  end

  defp command(owner, function) do
    ref = make_ref()
    send(owner, {:run, self(), ref, function})

    receive do
      {^ref, result} -> result
    after
      10_000 -> raise("owner did not respond")
    end
  end
end

for cells <- [1, 1000] do
  result = Filament.Bench.DeliveryComparison.run(cells, 1000)
  IO.puts("Paused owner; final value verified: " <> inspect(result))
end
