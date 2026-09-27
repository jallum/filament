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

  test "unchanged values still request resubscription for every saturated cell" do
    server = start_supervised!({CellPressureCounter, 1})
    owner = spawn_sleeper()
    on_exit(fn -> Process.exit(owner, :kill) end)
    first = subscribe_cell(server, owner, "first", 0)
    second = subscribe_cell(server, owner, "second", 0)
    # Warm the unchanged path before saturating its owner.
    CellPressureCounter.set(server, 1)
    flood_mailbox(owner, 110)

    capture_log(fn -> CellPressureCounter.set(server, 1) end)

    {:messages, messages} = Process.info(owner, :messages)
    assert {:cell_resubscribe, first} in messages
    assert {:cell_resubscribe, second} in messages
    refute Enum.any?(messages, &match?({:cell_update, _, _}, &1))
    assert CellPressureCounter.get_cell_entry(server, first).last == 1
    assert CellPressureCounter.get_cell_entry(server, second).last == 1
  end

  test "saturation of one owner does not suppress another owner's updates" do
    server = start_supervised!({CellPressureCounter, 1})
    owner = spawn_sleeper()
    on_exit(fn -> Process.exit(owner, :kill) end)
    blocked = subscribe_cell(server, owner, "blocked", 0)
    ready = subscribe_cell(server, self(), "ready", 0)
    flood_mailbox(owner, 110)

    capture_log(fn -> CellPressureCounter.set(server, 2) end)

    assert_receive {:cell_update, ^ready, 2}
    assert CellPressureCounter.get_cell_entry(server, blocked).last == 1
    assert CellPressureCounter.get_cell_entry(server, ready).last == 2
  end
end
