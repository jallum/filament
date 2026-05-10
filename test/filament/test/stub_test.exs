defmodule Filament.Test.StubTest do
  use ExUnit.Case

  alias Filament.Observable.Subscriber
  alias Filament.Test.Stub

  test "initial value returned via subscribe" do
    {:ok, stub} = Stub.start(fn _req -> 42 end)

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{{"root", 0} => true}
    }

    assert {:ok, 42} = Filament.Observable.subscribe(stub, sub)
  end

  test "push delivers raw state to all proj_keys in one message" do
    {:ok, stub} = Stub.start(fn _req -> 0 end)

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{{"fiber_a", 1} => true}
    }

    {:ok, _} = Filament.Observable.subscribe(stub, sub)
    Stub.push(stub, 99)
    assert_receive {:filament_observable_updates, [{"fiber_a", 1, 99}]}
  end

  test "push with unchanged raw state — no message sent (change-or-bust)" do
    {:ok, stub} = Stub.start(fn _req -> 0 end)

    sub = %Subscriber{
      pid: self(),
      proj_keys: %{{"fiber_b", 0} => true}
    }

    {:ok, 0} = Filament.Observable.subscribe(stub, sub)

    # First push triggers update (last_raw was :unset)
    Stub.push(stub, 3)
    assert_receive {:filament_observable_updates, [{"fiber_b", 0, 3}]}

    # Same value — no message
    Stub.push(stub, 3)
    refute_receive {:filament_observable_updates, _}, 50

    # Different value — message sent
    Stub.push(stub, 10)
    assert_receive {:filament_observable_updates, [{"fiber_b", 0, 10}]}
  end

  test "Stub.build/1 creates stubs for multiple servers" do
    {stubs_map, pids} =
      Stub.build([
        {:server_a, fn _ -> :a end},
        {:server_b, fn _ -> :b end}
      ])

    assert map_size(stubs_map) == 2
    assert length(pids) == 2
    assert Map.has_key?(stubs_map, :server_a)
    assert Map.has_key?(stubs_map, :server_b)
  end

end
