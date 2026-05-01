defmodule Filament.ObservableTest do
  use ExUnit.Case, async: true

  alias Filament.Observable
  alias Filament.Observable.Subscriber

  defmodule TestObservable do
    use GenServer

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid)
    end

    def init(test_pid), do: {:ok, test_pid}

    def handle_call({:filament_subscribe, request, subscriber}, _from, test_pid) do
      send(test_pid, {:got_subscribe, request, subscriber})
      {:reply, {:ok, :initial}, test_pid}
    end

    def handle_cast({:filament_unsubscribe, pid}, test_pid) do
      send(test_pid, {:got_unsubscribe, pid})
      {:noreply, test_pid}
    end
  end

  # --- Tests ---

  test "Subscriber struct enforces keys and defaults :last_projected to :unset" do
    assert_raise ArgumentError, fn ->
      struct!(Subscriber, fiber_id: "root", slot_index: 0, project: & &1)
    end

    sub = %Subscriber{
      pid: self(),
      fiber_id: :root,
      slot_index: 0,
      project: & &1
    }

    assert sub.pid == self()
    assert sub.fiber_id == :root
    assert sub.slot_index == 0
    assert sub.project.(42) == 42
    assert is_nil(sub.ref)
    assert sub.last_projected == :unset
  end

  test "subscribe/3 sends the correct GenServer.call message" do
    {:ok, pid} = TestObservable.start_link(self())

    sub = %Subscriber{
      pid: self(),
      fiber_id: :root,
      slot_index: 0,
      project: & &1
    }

    assert {:ok, :initial} = Observable.subscribe(pid, :my_request, sub)

    assert_receive {:got_subscribe, :my_request, received_sub}
    assert received_sub.fiber_id == :root
    assert received_sub.slot_index == 0
    assert received_sub.pid == self()
  end

  test "unsubscribe/2 sends the correct GenServer.cast message" do
    {:ok, pid} = TestObservable.start_link(self())

    me = self()
    :ok = Observable.unsubscribe(pid, me)

    assert_receive {:got_unsubscribe, ^me}
  end
end
