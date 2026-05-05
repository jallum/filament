defmodule Filament.ObservableTest do
  use ExUnit.Case, async: true

  alias Filament.Observable
  alias Filament.Observable.Subscriber

  defmodule TestObservable do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def init(test_pid), do: {:ok, test_pid}

    def handle_call({:filament_subscribe, subscriber}, _from, test_pid) do
      send(test_pid, {:got_subscribe, subscriber})
      {:reply, {:ok, :initial}, test_pid}
    end

    def handle_cast({:filament_remove_projection, sub_key, proj_key}, test_pid) do
      send(test_pid, {:got_remove_projection, sub_key, proj_key})
      {:noreply, test_pid}
    end
  end

  # --- Tests ---

  test "Subscriber struct enforces :pid, has proj_keys and last_raw" do
    assert_raise ArgumentError, fn ->
      struct!(Subscriber, proj_keys: %{})
    end

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{{"root", 0} => true}
    }

    assert sub.pid == self()
    assert sub.proj_keys == %{{"root", 0} => true}
    assert sub.last_raw == :unset
    assert is_nil(sub.ref)
  end

  test "subscribe/2 sends the correct GenServer.call message" do
    pid = start_supervised!({TestObservable, self()})

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{{"root", 0} => true}
    }

    assert {:ok, :initial} = Observable.subscribe(pid, sub)

    assert_receive {:got_subscribe, received_sub}
    assert received_sub.pid == self()
    assert received_sub.proj_keys == %{{"root", 0} => true}
  end

  test "remove_projection/4 sends the correct GenServer.cast message" do
    pid = start_supervised!({TestObservable, self()})

    :ok = Observable.remove_projection(pid, self(), "fiber_a", 2)

    assert_receive {:got_remove_projection, self_pid, {"fiber_a", 2}}
    assert self_pid == self()
  end
end
