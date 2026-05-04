defmodule Filament.ObservableTest do
  use ExUnit.Case, async: true

  alias Filament.Observable
  alias Filament.Observable.Subscriber

  defmodule TestObservable do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def init(test_pid), do: {:ok, test_pid}

    def handle_call({:filament_subscribe, request, subscriber}, _from, test_pid) do
      send(test_pid, {:got_subscribe, request, subscriber})
      {:reply, {:ok, :initial}, test_pid}
    end

    def handle_cast({:filament_remove_projection, sub_key, proj_key}, test_pid) do
      send(test_pid, {:got_remove_projection, sub_key, proj_key})
      {:noreply, test_pid}
    end
  end

  # --- Tests ---

  test "Subscriber struct enforces :pid and :request, has projections map" do
    assert_raise ArgumentError, fn ->
      struct!(Subscriber, pid: self())
    end

    sub = %Subscriber{
      pid: self(),
      request: :my_request,
      projections: %{{"root", 0} => {& &1, :unset}}
    }

    assert sub.pid == self()
    assert sub.request == :my_request
    assert map_size(sub.projections) == 1
    assert is_nil(sub.ref)
  end

  test "subscribe/3 sends the correct GenServer.call message" do
    pid = start_supervised!({TestObservable, self()})

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"root", 0} => {& &1, :unset}}
    }

    assert {:ok, :initial} = Observable.subscribe(pid, :my_request, sub)

    assert_receive {:got_subscribe, :my_request, received_sub}
    assert received_sub.pid == self()
    assert received_sub.request == nil
  end

  test "remove_projection/5 sends the correct GenServer.cast message" do
    pid = start_supervised!({TestObservable, self()})

    :ok = Observable.remove_projection(pid, self(), :req, "fiber_a", 2)

    assert_receive {:got_remove_projection, {self_pid, :req}, {"fiber_a", 2}}
    assert self_pid == self()
  end
end
