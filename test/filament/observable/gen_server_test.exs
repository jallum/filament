defmodule Filament.Observable.GenServerTest do
  use ExUnit.Case

  alias Filament.Observable
  alias Filament.Observable.Subscriber

  defmodule TestCounter do
    use Observable.GenServer

    def start_link(initial), do: GenServer.start_link(__MODULE__, initial)
    def init(n), do: {:ok, %{count: n}}

    def increment(pid), do: GenServer.call(pid, :increment)

    def handle_call(:increment, _from, state) do
      new_state = %{state | count: state.count + 1}
      notify_observers(new_state)
      {:reply, :ok, new_state}
    end
  end

  defmodule Minimal do
    use Observable.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, %{}}
  end

  defmodule Rejecting do
    use Observable.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, :no_state}

    @impl Filament.Observable
    def handle_subscribe(_request, _subscriber, state) do
      {:error, :rejected, state}
    end
  end

  defmodule WithTeardown do
    use Observable.GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def init(test_pid), do: {:ok, test_pid}

    @impl Filament.Observable
    def handle_unsubscribe(_subscriber, test_pid) do
      send(test_pid, :handle_unsubscribe_called)
      {:ok, test_pid}
    end
  end

  # --- Tests ---

  test "1. subscribe returns initial value" do
    {:ok, pid} = TestCounter.start_link(0)

    sub = %Subscriber{
      pid: self(),
      fiber_id: :root,
      slot_index: 0,
      project: fn s -> s.count end
    }

    # Default handle_subscribe returns {:ok, state, state}
    # so initial_value is the server state
    assert {:ok, %{count: 0}} = Observable.subscribe(pid, :any_request, sub)
  end

  test "2. notify delivers update" do
    {:ok, pid} = TestCounter.start_link(0)

    sub = %Subscriber{
      pid: self(),
      fiber_id: "root",
      slot_index: 0,
      project: fn s -> s.count end
    }

    assert {:ok, _} = Observable.subscribe(pid, :any_request, sub)
    :ok = TestCounter.increment(pid)

    assert_receive {:filament_observable_update, "root", 0, 1}
  end

  test "3. multiple subscribers each receive update" do
    {:ok, pid} = TestCounter.start_link(0)

    # First subscriber (self)
    assert {:ok, _} =
             Observable.subscribe(pid, :any, %Subscriber{
               pid: self(),
               fiber_id: :me,
               slot_index: 0,
               project: & &1.count
             })

    # Second subscriber (separate process)
    other = spawn_receiver(self(), :other)

    assert {:ok, _} =
             Observable.subscribe(pid, :any, %Subscriber{
               pid: other,
               fiber_id: :other,
               slot_index: 0,
               project: & &1.count
             })

    :ok = TestCounter.increment(pid)

    assert_receive {:filament_observable_update, :me, 0, 1}, 500
    assert_receive {:other_got_update, 1}, 500
  end

  test "4. DOWN removes subscriber" do
    {:ok, pid} = TestCounter.start_link(0)

    {:ok, dead_pid} = Agent.start(fn -> nil end)

    Observable.subscribe(pid, :any, %Subscriber{
      pid: dead_pid,
      fiber_id: :dead,
      slot_index: 0,
      project: & &1.count
    })

    # Kill the subscriber
    Process.exit(dead_pid, :kill)
    Process.sleep(50)

    # Verify observable still works — subscribe self and get update
    assert {:ok, _} =
             Observable.subscribe(pid, :any, %Subscriber{
               pid: self(),
               fiber_id: :alive,
               slot_index: 1,
               project: & &1.count
             })

    :ok = TestCounter.increment(pid)

    # Should only receive once (for alive subscriber), confirming dead subscriber was removed
    assert_receive {:filament_observable_update, :alive, 1, 1}, 500
    refute_received {:filament_observable_update, :dead, 0, 1}, 50
  end

  test "5. unsubscribe removes subscriber" do
    {:ok, pid} = TestCounter.start_link(0)

    sub = %Subscriber{
      pid: self(),
      fiber_id: :root,
      slot_index: 0,
      project: & &1.count
    }

    assert {:ok, _} = Observable.subscribe(pid, :any, sub)
    :ok = Observable.unsubscribe(pid, self())

    Process.sleep(50)

    :ok = TestCounter.increment(pid)
    refute_receive {:filament_observable_update, _, _, _}, 100
  end

  test "6. handle_unsubscribe called on DOWN" do
    {:ok, observable} = WithTeardown.start_link(self())

    {:ok, dead_pid} = Agent.start(fn -> nil end)

    assert {:ok, _} =
             Observable.subscribe(observable, :any, %Subscriber{
               pid: dead_pid,
               fiber_id: :root,
               slot_index: 0,
               project: & &1
             })

    Process.exit(dead_pid, :kill)

    assert_receive :handle_unsubscribe_called, 500
  end

  test "7. subscribe rejected by handle_subscribe" do
    {:ok, pid} = Rejecting.start_link()

    sub = %Subscriber{
      pid: self(),
      fiber_id: :root,
      slot_index: 0,
      project: & &1
    }

    assert {:error, :rejected} = Observable.subscribe(pid, :any, sub)
    assert Process.alive?(pid)
  end

  test "8. minimal module compiles without custom callbacks" do
    {:ok, pid} = Minimal.start_link()
    assert Process.alive?(pid)
  end

  # --- Projection tests (D3) ---

  defmodule ProjectionCounter do
    use Observable.GenServer

    def start_link(n), do: GenServer.start_link(__MODULE__, n)
    def init(n), do: {:ok, n}
    def set(pid, n), do: GenServer.call(pid, {:set, n})

    def handle_call({:set, n}, _from, _state) do
      notify_observers(n)
      {:reply, :ok, n}
    end
  end

  test "9. first notification always fires (last_projected == :unset)" do
    {:ok, pid} = ProjectionCounter.start_link(0)

    assert {:ok, _} =
             Observable.subscribe(pid, :any, %Subscriber{
               pid: self(),
               fiber_id: :root,
               slot_index: 0,
               project: fn n -> n > 5 end
             })

    ProjectionCounter.set(pid, 3)
    assert_receive {:filament_observable_update, :root, 0, false}
  end

  test "10. change triggers notification" do
    {:ok, pid} = ProjectionCounter.start_link(0)

    assert {:ok, _} =
             Observable.subscribe(pid, :any, %Subscriber{
               pid: self(),
               fiber_id: :root,
               slot_index: 0,
               project: fn n -> n > 5 end
             })

    ProjectionCounter.set(pid, 3)
    assert_receive {:filament_observable_update, :root, 0, false}

    ProjectionCounter.set(pid, 10)
    assert_receive {:filament_observable_update, :root, 0, true}
  end

  test "11. no-change skips notification" do
    {:ok, pid} = ProjectionCounter.start_link(0)

    assert {:ok, _} =
             Observable.subscribe(pid, :any, %Subscriber{
               pid: self(),
               fiber_id: :root,
               slot_index: 0,
               project: fn n -> n > 5 end
             })

    ProjectionCounter.set(pid, 1)
    assert_receive {:filament_observable_update, :root, 0, false}

    # Still false → skip
    ProjectionCounter.set(pid, 2)
    refute_receive {:filament_observable_update, :root, 0, false}, 50
  end

  test "12. nil projection survives" do
    {:ok, pid} = ProjectionCounter.start_link(0)

    assert {:ok, _} =
             Observable.subscribe(pid, :any, %Subscriber{
               pid: self(),
               fiber_id: :root,
               slot_index: 0,
               project: fn _ -> nil end
             })

    ProjectionCounter.set(pid, 1)
    assert_receive {:filament_observable_update, :root, 0, nil}

    ProjectionCounter.set(pid, 2)
    refute_receive {:filament_observable_update, :root, 0, nil}, 50
  end

  test "13. multiple subscribers with different projections" do
    {:ok, pid} = ProjectionCounter.start_link(0)

    # Use a simple sleeping process as one subscriber so both are stored
    other = spawn(fn -> Process.sleep(:infinity) end)

    # Subscriber A: pass-through (via self)
    assert {:ok, _} =
             Observable.subscribe(pid, :any, %Subscriber{
               pid: self(),
               fiber_id: :me,
               slot_index: 0,
               project: & &1
             })

    # Subscriber B: bool projection (via sleeping process)
    assert {:ok, _} =
             Observable.subscribe(pid, :any, %Subscriber{
               pid: other,
               fiber_id: :b,
               slot_index: 0,
               project: fn n -> n > 5 end
             })

    # Set to 3 — both subscribers get first update
    ProjectionCounter.set(pid, 3)
    assert_receive {:filament_observable_update, :me, 0, 3}, 200

    # Nothing else for us
    refute_receive {:filament_observable_update, :me, 0, _}, 50

    # Set to 4: me gets update (4 !== 3), B's other process gets nothing (false === false)
    ProjectionCounter.set(pid, 4)
    assert_receive {:filament_observable_update, :me, 0, 4}, 200

    Process.exit(other, :kill)
  end

  # --- Helpers ---

  defp spawn_receiver(parent, _id) do
    spawn(fn ->
      receive do
        {:filament_observable_update, _fid, _idx, value} ->
          send(parent, {:other_got_update, value})
      after
        500 -> :timeout
      end
    end)
  end
end
