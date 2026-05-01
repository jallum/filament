defmodule Filament.Observable.BackpressureTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Filament.{Observable, Observable.Subscriber}

  defmodule PressureCounter do
    use Observable.GenServer

    def start_link(n), do: GenServer.start_link(__MODULE__, n)
    def init(n), do: {:ok, n}
    def set(pid, n), do: GenServer.call(pid, {:set, n})

    def get_subscriber(pid, subscriber_pid),
      do: GenServer.call(pid, {:get_subscriber, subscriber_pid})

    def handle_call({:set, n}, _from, _state) do
      notify_observers(n)
      {:reply, :ok, n}
    end

    def handle_call({:get_subscriber, subscriber_pid}, _from, state) do
      subs = Process.get(:__filament_subscribers__, %{})
      {:reply, Map.get(subs, subscriber_pid), state}
    end
  end

  # --- Test helpers ---

  defp spawn_sleeper do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  defp flood_mailbox(pid, count) do
    for _ <- 1..count, do: send(pid, :__flood__)
  end

  defp drain_sleeper_mailbox(pid) do
    Process.exit(pid, :kill)
  end

  defp get_subscriber_state(observable, subscriber_pid) do
    PressureCounter.get_subscriber(observable, subscriber_pid)
  end

  # --- Tests ---

  test "1. normal delivery with empty mailbox" do
    {:ok, observable} = PressureCounter.start_link(1)
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, :any, %Subscriber{
      pid: sub_pid,
      fiber_id: :root,
      slot_index: 0,
      project: & &1
    })

    PressureCounter.set(observable, 2)

    # Sub should have update, not resubscribe
    {:messages, msgs} = Process.info(sub_pid, :messages)
    assert Enum.any?(msgs, &match?({:filament_observable_update, :root, 0, 2}, &1))
    refute Enum.any?(msgs, &match?({:filament_observable_resubscribe, _, _}, &1))

    drain_sleeper_mailbox(sub_pid)
  end

  test "2. saturated subscriber receives resubscribe, not update" do
    {:ok, observable} = PressureCounter.start_link(1)
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, :any, %Subscriber{
      pid: sub_pid,
      fiber_id: :root,
      slot_index: 0,
      project: & &1
    })

    # Flood the subscriber's mailbox to >= threshold of 100
    flood_mailbox(sub_pid, 110)

    capture_log(fn ->
      PressureCounter.set(observable, 2)
      Logger.flush()
    end)

    {:messages, msgs} = Process.info(sub_pid, :messages)

    # Should have resubscribe, NOT update
    assert Enum.any?(msgs, &match?({:filament_observable_resubscribe, :root, 0}, &1))
    refute Enum.any?(msgs, &match?({:filament_observable_update, _, _, _}, &1))

    drain_sleeper_mailbox(sub_pid)
  end

  test "3. last_projected not updated on saturation" do
    {:ok, observable} = PressureCounter.start_link(1)

    # First: subscribe with non-saturated mailbox, set to 1
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, :any, %Subscriber{
      pid: sub_pid,
      fiber_id: :root,
      slot_index: 0,
      project: & &1
    })

    PressureCounter.set(observable, 1)

    # Verify last_projected was updated
    sub = get_subscriber_state(observable, sub_pid)
    assert sub.last_projected == 1

    drain_sleeper_mailbox(sub_pid)

    # Now: subscribe with flooded mailbox, set to 2
    sub_pid2 = spawn_sleeper()

    Observable.subscribe(observable, :any, %Subscriber{
      pid: sub_pid2,
      fiber_id: :root,
      slot_index: 0,
      project: & &1
    })

    flood_mailbox(sub_pid2, 110)

    capture_log(fn ->
      PressureCounter.set(observable, 2)
      Logger.flush()
    end)

    # last_projected should still be :unset (never updated)
    sub_after = get_subscriber_state(observable, sub_pid2)
    assert sub_after.last_projected == :unset

    drain_sleeper_mailbox(sub_pid2)
  end

  test "4. dead process handled gracefully" do
    {:ok, observable} = PressureCounter.start_link(1)
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, :any, %Subscriber{
      pid: sub_pid,
      fiber_id: :root,
      slot_index: 0,
      project: & &1
    })

    # Kill without waiting for DOWN (background cleanup)
    Process.exit(sub_pid, :kill)
    Process.sleep(50)

    # This used to crash with a FunctionClauseError on nil if not handled
    capture_log(fn ->
      assert :ok = PressureCounter.set(observable, 99)
      Logger.flush()
    end)
  end

  test "5. warning logged on saturation" do
    {:ok, observable} = PressureCounter.start_link(1)
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, :any, %Subscriber{
      pid: sub_pid,
      fiber_id: :backpressure_test,
      slot_index: 0,
      project: & &1
    })

    flood_mailbox(sub_pid, 110)

    logs =
      capture_log(fn ->
        PressureCounter.set(observable, 2)
        Logger.flush()
      end)

    assert logs =~ "subscriber"
    assert logs =~ "saturated"

    drain_sleeper_mailbox(sub_pid)
  end
end
