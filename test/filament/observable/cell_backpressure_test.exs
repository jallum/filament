defmodule Filament.Observable.CellBackpressureTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Filament.Cell

  defmodule CellPressureCounter do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link(n), do: GenServer.start_link(__MODULE__, n)
    def init(n), do: {:ok, n}
    def set(pid, n), do: GenServer.call(pid, {:set, n})
    def get_cell_entry(pid, sub), do: GenServer.call(pid, {:get_cell_entry, sub})

    def handle_call({:set, n}, _from, _state) do
      notify_observers(n)
      {:reply, :ok, n}
    end

    def handle_call({:get_cell_entry, sub}, _from, state) do
      cell_subs = Process.get(:__filament_cell_subscribers__, %{})
      {:reply, Map.get(cell_subs, sub), state}
    end
  end

  defp spawn_sleeper, do: spawn(fn -> Process.sleep(:infinity) end)
  defp flood_mailbox(pid, n), do: for(_ <- 1..n, do: send(pid, :__flood__))
  defp drain_sleeper_mailbox(pid), do: Process.exit(pid, :kill)

  defp subscribe_cell(server, sub_pid, fiber_id, slot_index) do
    cell = Filament.Source.new(Filament.Observable.GenServer, server)
    subscriber = {sub_pid, fiber_id, slot_index}
    {:ok, _} = Cell.subscribe(cell, subscriber, &Function.identity/1)
    subscriber
  end

  test "1. normal delivery sends :cell_update" do
    server = start_supervised!({CellPressureCounter, 1})
    sub_pid = spawn_sleeper()
    sub = subscribe_cell(server, sub_pid, "root", 0)

    CellPressureCounter.set(server, 2)

    {:messages, msgs} = Process.info(sub_pid, :messages)
    assert Enum.any?(msgs, &match?({:cell_update, ^sub, 2}, &1))
    refute Enum.any?(msgs, &match?({:cell_resubscribe, _}, &1))

    drain_sleeper_mailbox(sub_pid)
  end

  test "2. saturated subscriber receives :cell_resubscribe, not :cell_update" do
    server = start_supervised!({CellPressureCounter, 1})
    sub_pid = spawn_sleeper()
    sub = subscribe_cell(server, sub_pid, "root", 0)

    flood_mailbox(sub_pid, 110)

    capture_log(fn ->
      CellPressureCounter.set(server, 2)
      Logger.flush()
    end)

    {:messages, msgs} = Process.info(sub_pid, :messages)

    assert Enum.any?(msgs, &match?({:cell_resubscribe, ^sub}, &1))
    refute Enum.any?(msgs, &match?({:cell_update, _, _}, &1))

    drain_sleeper_mailbox(sub_pid)
  end

  test "3. last is not advanced on saturation" do
    server = start_supervised!({CellPressureCounter, 1})
    sub_pid = spawn_sleeper()
    sub = subscribe_cell(server, sub_pid, "root", 0)

    flood_mailbox(sub_pid, 110)

    capture_log(fn ->
      CellPressureCounter.set(server, 2)
      Logger.flush()
    end)

    entry = CellPressureCounter.get_cell_entry(server, sub)
    # Initial subscribe captured last=1; saturation prevented bump to 2.
    assert entry.last == 1

    drain_sleeper_mailbox(sub_pid)
  end

  test "4. dead process handled gracefully" do
    server = start_supervised!({CellPressureCounter, 1})
    sub_pid = spawn_sleeper()
    _sub = subscribe_cell(server, sub_pid, "root", 0)

    Process.exit(sub_pid, :kill)
    Process.sleep(50)

    capture_log(fn ->
      assert :ok = CellPressureCounter.set(server, 99)
      Logger.flush()
    end)
  end

  test "5. warning logged on saturation" do
    server = start_supervised!({CellPressureCounter, 1})
    sub_pid = spawn_sleeper()
    _sub = subscribe_cell(server, sub_pid, "root", 0)

    flood_mailbox(sub_pid, 110)

    logs =
      capture_log(fn ->
        CellPressureCounter.set(server, 2)
        Logger.flush()
      end)

    assert logs =~ "cell subscriber"
    assert logs =~ "saturated"

    drain_sleeper_mailbox(sub_pid)
  end
end
