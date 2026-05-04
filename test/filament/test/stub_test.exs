defmodule Filament.Test.StubTest do
  use ExUnit.Case

  alias Filament.Observable.Subscriber
  alias Filament.Test.Stub

  test "initial value returned via subscribe" do
    {:ok, stub} = Stub.start(fn _req -> 42 end)

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"root", 0} => {&Function.identity/1, :unset}}
    }

    assert {:ok, 42} = Filament.Observable.subscribe(stub, nil, sub)
  end

  test "push delivers batched update to subscriber" do
    {:ok, stub} = Stub.start(fn _req -> 0 end)

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"fiber_a", 1} => {&Function.identity/1, :unset}}
    }

    {:ok, _} = Filament.Observable.subscribe(stub, nil, sub)
    Stub.push(stub, 99)
    assert_receive {:filament_observable_updates, [{"fiber_a", 1, 99}]}
  end

  test "push with projection — dedup applies per projection" do
    {:ok, stub} = Stub.start(fn _req -> 0 end)

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"fiber_b", 0} => {fn n -> n > 5 end, :unset}}
    }

    {:ok, 0} = Filament.Observable.subscribe(stub, nil, sub)

    # First push always notifies (last_projected starts as :unset)
    Stub.push(stub, 3)
    assert_receive {:filament_observable_updates, [{"fiber_b", 0, false}]}

    # Projected value unchanged — no message
    Stub.push(stub, 4)
    refute_receive {:filament_observable_updates, _}, 50

    # Projected value changes
    Stub.push(stub, 10)
    assert_receive {:filament_observable_updates, [{"fiber_b", 0, true}]}
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

  test "use_observable resolves stub via observable_stubs in RenderContext" do
    {:ok, stub} = Stub.start(fn _req -> :stub_value end)

    _fiber = %Filament.Fiber{
      id: :test_fiber,
      component: nil,
      props: %{},
      hook_slots: %{},
      event_handlers: %{},
      children: [],
      parent_id: nil,
      status: :stable
    }

    ctx = %Filament.RenderContext{
      fiber_id: :test_fiber,
      fiber_tree: %{},
      hook_index: 0,
      new_hook_slots: %{},
      pending_effects: [],
      event_handler_index: 0,
      new_event_handlers: %{},
      observable_stubs: %{:my_server => stub},
      owner_pid: self()
    }

    Process.put(:filament_render_context, ctx)

    try do
      {_server, value} = Filament.Hooks.use_observable(:my_server, project: &Function.identity/1)
      assert value == :stub_value
    after
      Process.delete(:filament_render_context)
    end
  end
end
