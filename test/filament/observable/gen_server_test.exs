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

  defmodule AlwaysRejecting do
    @moduledoc false
    use Observable.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, :no_state}

    @impl Observable
    def handle_subscribe(_subscriber, state), do: {:error, :rejected, state}
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
      proj_keys: %{{"root", 0} => true}
    }

    assert {:ok, %{count: 0}} = Observable.subscribe(pid, sub)
  end

  test "2. notify_observers sends raw state as :filament_observable_updates" do
    pid = start_supervised!({TestCounter, 0})

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{{"root", 0} => true}
    }

    assert {:ok, _} = Observable.subscribe(pid, sub)
    :ok = TestCounter.increment(pid)

    assert_receive {:filament_observable_updates, [{"root", 0, %{count: 1}}]}
  end

  test "3. multiple proj_keys in one subscriber delivered in one message" do
    pid = start_supervised!({TestCounter, 0})

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{
        {"fiber_a", 0} => true,
        {"fiber_b", 1} => true
      }
    }

    assert {:ok, _} = Observable.subscribe(pid, sub)
    :ok = TestCounter.increment(pid)

    assert_receive {:filament_observable_updates, updates}
    assert length(updates) == 2
    assert Enum.all?(updates, fn {_, _, v} -> v == %{count: 1} end)
    assert {"fiber_a", 0, %{count: 1}} in updates
    assert {"fiber_b", 1, %{count: 1}} in updates
  end

  test "4. no update sent when raw state is unchanged (change-or-bust)" do
    pid = start_supervised!({TestCounter, 0})

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{{"root", 0} => true}
    }

    assert {:ok, _} = Observable.subscribe(pid, sub)

    # First increment triggers update
    TestCounter.increment(pid)
    assert_receive {:filament_observable_updates, _}

    # No second increment — same raw state means no further message
    refute_receive {:filament_observable_updates, _}, 50
  end

  test "5. two different pids each get their own batched message" do
    pid = start_supervised!({TestCounter, 0})
    other = spawn(fn -> Process.sleep(:infinity) end)

    sub_self = %Subscriber{
      pid: self(),
      proj_keys: %{{"me", 0} => true}
    }

    sub_other = %Subscriber{
      pid: other,
      proj_keys: %{{"other", 0} => true}
    }

    {:ok, _} = Observable.subscribe(pid, sub_self)
    {:ok, _} = Observable.subscribe(pid, sub_other)

    assert map_size(TestCounter.get_subs(pid)) == 2

    TestCounter.increment(pid)

    assert_receive {:filament_observable_updates, [{"me", 0, %{count: 1}}]}

    {:messages, other_msgs} = Process.info(other, :messages)
    assert {:filament_observable_updates, [{"other", 0, %{count: 1}}]} in other_msgs

    Process.exit(other, :kill)
  end

  test "6. second subscriber on same pid merges proj_keys" do
    pid = start_supervised!({TestCounter, 0})

    sub1 = %Subscriber{pid: self(), proj_keys: %{{"fiber_a", 0} => true}}
    sub2 = %Subscriber{pid: self(), proj_keys: %{{"fiber_b", 1} => true}}

    {:ok, _} = Observable.subscribe(pid, sub1)
    {:ok, _} = Observable.subscribe(pid, sub2)

    assert map_size(TestCounter.get_subs(pid)) == 1

    TestCounter.increment(pid)
    assert_receive {:filament_observable_updates, updates}
    assert {"fiber_a", 0, %{count: 1}} in updates
    assert {"fiber_b", 1, %{count: 1}} in updates
  end

  test "7. remove_projection auto-unsubscribes when last proj_key removed" do
    pid = start_supervised!({TestCounter, 0})

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{{"root", 0} => true}
    }

    {:ok, _} = Observable.subscribe(pid, sub)
    assert map_size(TestCounter.get_subs(pid)) == 1

    Observable.remove_projection(pid, self(), "root", 0)
    # Flush cast
    _ = TestCounter.get_subs(pid)
    assert map_size(TestCounter.get_subs(pid)) == 0
  end

  test "8. DOWN removes subscriber and calls handle_unsubscribe" do
    observable = start_supervised!({WithTeardown, self()})
    {:ok, dead_pid} = Agent.start(fn -> nil end)

    sub = %Subscriber{
      pid: dead_pid,
      proj_keys: %{{"root", 0} => true}
    }

    {:ok, _} = Observable.subscribe(observable, sub)
    Process.exit(dead_pid, :kill)

    assert_receive :handle_unsubscribe_called, 500
  end

  test "9. subscribe rejected by handle_subscribe" do
    pid = start_supervised!(%{id: AlwaysRejecting, start: {AlwaysRejecting, :start_link, []}})

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{{"root", 0} => true}
    }

    assert {:error, :rejected} = Observable.subscribe(pid, sub)
    assert Process.alive?(pid)
  end

  test "10. minimal module compiles without custom callbacks" do
    pid = start_supervised!(%{id: Minimal, start: {Minimal, :start_link, []}})
    assert Process.alive?(pid)
  end
end
