defmodule Filament.Observable.BackpressureTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Filament.Observable
  alias Filament.Observable.Subscriber

  defmodule PressureCounter do
    @moduledoc false
    use Observable.GenServer

    def start_link(n), do: GenServer.start_link(__MODULE__, n)
    def init(n), do: {:ok, n}
    def set(pid, n), do: GenServer.call(pid, {:set, n})
    def get_subscriber(pid, sub_key), do: GenServer.call(pid, {:get_subscriber, sub_key})

    def handle_call({:set, n}, _from, _state) do
      notify_observers(n)
      {:reply, :ok, n}
    end

    def handle_call({:get_subscriber, sub_key}, _from, state) do
      subs = Process.get(:__filament_subscribers__, %{})
      {:reply, Map.get(subs, sub_key), state}
    end
  end

  defp spawn_sleeper, do: spawn(fn -> Process.sleep(:infinity) end)
  defp flood_mailbox(pid, n), do: for(_ <- 1..n, do: send(pid, :__flood__))
  defp drain_sleeper_mailbox(pid), do: Process.exit(pid, :kill)

  defp get_subscriber(obs, pid), do: PressureCounter.get_subscriber(obs, pid)

  # --- Tests ---

  test "1. normal delivery with empty mailbox" do
    observable = start_supervised!({PressureCounter, 1})
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, %Subscriber{
      pid: sub_pid,
      proj_keys: %{{"root", 0} => true}
    })

    PressureCounter.set(observable, 2)

    {:messages, msgs} = Process.info(sub_pid, :messages)
    assert Enum.any?(msgs, &match?({:filament_observable_updates, [{"root", 0, 2}]}, &1))
    refute Enum.any?(msgs, &match?({:filament_observable_resubscribe, _, _}, &1))

    drain_sleeper_mailbox(sub_pid)
  end

  test "2. saturated subscriber receives resubscribe per proj_key, not update" do
    observable = start_supervised!({PressureCounter, 1})
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, %Subscriber{
      pid: sub_pid,
      proj_keys: %{{"root", 0} => true}
    })

    flood_mailbox(sub_pid, 110)

    capture_log(fn ->
      PressureCounter.set(observable, 2)
      Logger.flush()
    end)

    {:messages, msgs} = Process.info(sub_pid, :messages)

    assert Enum.any?(msgs, &match?({:filament_observable_resubscribe, "root", 0}, &1))
    refute Enum.any?(msgs, &match?({:filament_observable_updates, _}, &1))

    drain_sleeper_mailbox(sub_pid)
  end

  test "3. last_raw not updated on saturation" do
    observable = start_supervised!({PressureCounter, 1})
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, %Subscriber{
      pid: sub_pid,
      proj_keys: %{{"root", 0} => true}
    })

    PressureCounter.set(observable, 1)

    sub = get_subscriber(observable, sub_pid)
    assert sub.last_raw == 1

    drain_sleeper_mailbox(sub_pid)

    sub_pid2 = spawn_sleeper()

    Observable.subscribe(observable, %Subscriber{
      pid: sub_pid2,
      proj_keys: %{{"root", 0} => true}
    })

    flood_mailbox(sub_pid2, 110)

    capture_log(fn ->
      PressureCounter.set(observable, 2)
      Logger.flush()
    end)

    sub_after = get_subscriber(observable, sub_pid2)
    # last_raw stays at the subscribe-time initial value (1); saturation prevented
    # it from being updated to 2.
    assert sub_after.last_raw == 1

    drain_sleeper_mailbox(sub_pid2)
  end

  test "4. dead process handled gracefully" do
    observable = start_supervised!({PressureCounter, 1})
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, %Subscriber{
      pid: sub_pid,
      proj_keys: %{{"root", 0} => true}
    })

    Process.exit(sub_pid, :kill)
    Process.sleep(50)

    capture_log(fn ->
      assert :ok = PressureCounter.set(observable, 99)
      Logger.flush()
    end)
  end

  test "5. warning logged on saturation" do
    observable = start_supervised!({PressureCounter, 1})
    sub_pid = spawn_sleeper()

    Observable.subscribe(observable, %Subscriber{
      pid: sub_pid,
      proj_keys: %{{"backpressure_test", 0} => true}
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

  test "one saturation notice per projection per episode, then fresh delivery after resubscription" do
    observable = start_supervised!({PressureCounter, 0})

    owner = spawn(fn -> drainable_owner() end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    subscriber = %Subscriber{pid: owner, proj_keys: %{{"first", 0} => true, {"second", 0} => true}}
    assert {:ok, 0} = Observable.subscribe(observable, subscriber)
    assert {:ok, 0} = Observable.subscribe(observable, %Subscriber{pid: self(), proj_keys: %{{"healthy", 0} => true}})
    flood_mailbox(owner, 110)

    logs =
      capture_log(fn ->
        for value <- 1..20, do: PressureCounter.set(observable, value)
        Logger.flush()
      end)

    assert length(Regex.scan(~r/mailbox saturated/, logs)) == 1
    {:messages, messages} = Process.info(owner, :messages)
    assert Enum.count(messages, &match?({:filament_observable_resubscribe, _, _}, &1)) == 2
    assert length(messages) == 112
    refute Enum.any?(messages, &match?({:filament_observable_updates, _}, &1))
    assert_receive {:filament_observable_updates, [{"healthy", 0, 20}]}
    assert get_subscriber(observable, owner).last_raw == 0
    ref = make_ref()
    send(owner, {:drain, self(), ref})
    assert_receive {:drained, ^ref}
    assert {:ok, 20} = Observable.subscribe(observable, subscriber)
    assert get_subscriber(observable, owner).last_raw == 20
    assert capture_log(fn -> PressureCounter.set(observable, 20) end) == ""
    assert {:messages, []} = Process.info(owner, :messages)
    PressureCounter.set(observable, 21)
    {:messages, messages} = Process.info(owner, :messages)
    assert [{:filament_observable_updates, updates}] = messages
    assert Enum.sort(updates) == [{"first", 0, 21}, {"second", 0, 21}]
    flood_mailbox(owner, 110)

    logs =
      capture_log(fn ->
        for value <- 22..25, do: PressureCounter.set(observable, value)
        Logger.flush()
      end)

    assert length(Regex.scan(~r/mailbox saturated/, logs)) == 1
    {:messages, messages} = Process.info(owner, :messages)
    assert Enum.count(messages, &match?({:filament_observable_resubscribe, _, _}, &1)) == 2
  end

  test "stale session handoff recovers current state instead of the abandoned snapshot" do
    observable = start_supervised!({PressureCounter, 0})
    old_owner = spawn_sleeper()
    new_owner = spawn_sleeper()

    on_exit(fn ->
      Process.exit(old_owner, :kill)
      Process.exit(new_owner, :kill)
    end)

    sub = %Subscriber{pid: old_owner, proj_keys: %{{"root", 0} => true}, session_token: "recover-session"}
    assert {:ok, 0} = Observable.subscribe(observable, sub)
    flood_mailbox(old_owner, 110)
    capture_log(fn -> PressureCounter.set(observable, 1) end)
    assert get_subscriber(observable, old_owner).stale
    assert {:ok, 1} = Observable.subscribe(observable, %{sub | pid: new_owner})
    assert get_subscriber(observable, old_owner) == nil
    refute get_subscriber(observable, new_owner).stale
    PressureCounter.set(observable, 2)
    assert {:messages, [{:filament_observable_updates, [{"root", 0, 2}]}]} = Process.info(new_owner, :messages)
  end

  defp drainable_owner do
    receive do
      {:drain, caller, ref} ->
        drain_mailbox()
        send(caller, {:drained, ref})
        drainable_owner()
    end
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      0 -> :ok
    end
  end
end
