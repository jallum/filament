defmodule Filament.Observable.GenServerTest do
  use ExUnit.Case

  alias Filament.Observable
  alias Filament.Observable.Subscriber

  defmodule TestCounter do
    @moduledoc false
    use Observable.GenServer

    def start_link(initial), do: GenServer.start_link(__MODULE__, initial)
    def init(n), do: {:ok, %{count: n}}

    def increment(pid), do: GenServer.call(pid, :increment)
    def get_subs(pid), do: GenServer.call(pid, :__test_get_subs__)

    def handle_call(:increment, _from, state) do
      new_state = %{state | count: state.count + 1}
      notify_observers(new_state)
      {:reply, :ok, new_state}
    end

    def handle_call(:__test_get_subs__, _from, state) do
      {:reply, Process.get(:__filament_subscribers__, %{}), state}
    end
  end

  defmodule Minimal do
    @moduledoc false
    use Observable.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, %{}}
  end

  defmodule Rejecting do
    @moduledoc false
    use Observable.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, :no_state}

    @impl Observable
    def handle_subscribe(:reject_me, _subscriber, state), do: {:error, :rejected, state}
    def handle_subscribe(_request, _subscriber, state), do: {:ok, state, state}
  end

  defmodule WithTeardown do
    @moduledoc false
    use Observable.GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def init(test_pid), do: {:ok, test_pid}

    @impl Observable
    def handle_unsubscribe(_subscriber, test_pid) do
      send(test_pid, :handle_unsubscribe_called)
      {:ok, test_pid}
    end
  end

  # --- Subscription ---

  test "1. subscribe returns raw initial state" do
    pid = start_supervised!({TestCounter, 0})

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"root", 0} => {fn s -> s.count end, :unset}}
    }

    assert {:ok, %{count: 0}} = Observable.subscribe(pid, nil, sub)
  end

  test "2. notify_observers sends batched :filament_observable_updates" do
    pid = start_supervised!({TestCounter, 0})

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"root", 0} => {fn s -> s.count end, :unset}}
    }

    assert {:ok, _} = Observable.subscribe(pid, nil, sub)
    :ok = TestCounter.increment(pid)

    assert_receive {:filament_observable_updates, [{"root", 0, 1}]}
  end

  test "3. multiple projections in one subscriber delivered in one message" do
    pid = start_supervised!({TestCounter, 0})

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{
        {"fiber_a", 0} => {fn s -> s.count end, :unset},
        {"fiber_b", 1} => {fn s -> s.count * 10 end, :unset}
      }
    }

    assert {:ok, _} = Observable.subscribe(pid, nil, sub)
    :ok = TestCounter.increment(pid)

    assert_receive {:filament_observable_updates, updates}
    assert length(updates) == 2
    assert {"fiber_a", 0, 1} in updates
    assert {"fiber_b", 1, 10} in updates
  end

  test "4. unchanged projections omitted from batched message" do
    pid = start_supervised!({TestCounter, 5})

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{
        {"fiber_a", 0} => {fn s -> s.count > 5 end, :unset},
        {"fiber_b", 1} => {fn s -> s.count end, :unset}
      }
    }

    {:ok, _} = Observable.subscribe(pid, nil, sub)

    # First increment: both fire (last_projected was :unset)
    TestCounter.increment(pid)
    assert_receive {:filament_observable_updates, updates1}
    assert {"fiber_a", 0, true} in updates1
    assert {"fiber_b", 1, 6} in updates1

    # Second: fiber_a projection (count > 5) is still true — omitted
    TestCounter.increment(pid)
    assert_receive {:filament_observable_updates, updates2}
    refute Enum.any?(updates2, fn {fid, _, _} -> fid == "fiber_a" end)
    assert {"fiber_b", 1, 7} in updates2
  end

  test "5. second subscriber on same {pid, request} merges projections" do
    pid = start_supervised!({TestCounter, 0})

    sub1 = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"fiber_a", 0} => {fn s -> s.count end, :unset}}
    }

    sub2 = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"fiber_b", 1} => {fn s -> s.count * 100 end, :unset}}
    }

    {:ok, _} = Observable.subscribe(pid, nil, sub1)
    {:ok, _} = Observable.subscribe(pid, nil, sub2)

    assert map_size(TestCounter.get_subs(pid)) == 1

    TestCounter.increment(pid)
    assert_receive {:filament_observable_updates, updates}
    assert {"fiber_a", 0, 1} in updates
    assert {"fiber_b", 1, 100} in updates
  end

  test "6. two different pids each get their own batched message" do
    pid = start_supervised!({TestCounter, 0})
    other = spawn(fn -> Process.sleep(:infinity) end)

    sub_self = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"me", 0} => {fn s -> s.count end, :unset}}
    }

    sub_other = %Subscriber{
      pid: other,
      request: nil,
      projections: %{{"other", 0} => {fn s -> s.count * 2 end, :unset}}
    }

    {:ok, _} = Observable.subscribe(pid, nil, sub_self)
    {:ok, _} = Observable.subscribe(pid, nil, sub_other)

    assert map_size(TestCounter.get_subs(pid)) == 2

    TestCounter.increment(pid)

    assert_receive {:filament_observable_updates, [{"me", 0, 1}]}

    {:messages, other_msgs} = Process.info(other, :messages)
    assert {:filament_observable_updates, [{"other", 0, 2}]} in other_msgs

    Process.exit(other, :kill)
  end

  test "7. remove_projection auto-unsubscribes when last projection removed" do
    pid = start_supervised!({TestCounter, 0})

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"root", 0} => {fn s -> s.count end, :unset}}
    }

    {:ok, _} = Observable.subscribe(pid, nil, sub)
    assert map_size(TestCounter.get_subs(pid)) == 1

    Observable.remove_projection(pid, self(), nil, "root", 0)
    # Flush cast
    _ = TestCounter.get_subs(pid)
    assert map_size(TestCounter.get_subs(pid)) == 0
  end

  test "8. DOWN removes subscriber and calls handle_unsubscribe" do
    observable = start_supervised!({WithTeardown, self()})
    {:ok, dead_pid} = Agent.start(fn -> nil end)

    sub = %Subscriber{
      pid: dead_pid,
      request: nil,
      projections: %{{"root", 0} => {& &1, :unset}}
    }

    {:ok, _} = Observable.subscribe(observable, nil, sub)
    Process.exit(dead_pid, :kill)

    assert_receive :handle_unsubscribe_called, 500
  end

  test "9. subscribe rejected by handle_subscribe" do
    pid = start_supervised!(%{id: Rejecting, start: {Rejecting, :start_link, []}})

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"root", 0} => {& &1, :unset}}
    }

    assert {:error, :rejected} = Observable.subscribe(pid, :reject_me, sub)
    assert Process.alive?(pid)
  end

  test "10. minimal module compiles without custom callbacks" do
    pid = start_supervised!(%{id: Minimal, start: {Minimal, :start_link, []}})
    assert Process.alive?(pid)
  end
end
