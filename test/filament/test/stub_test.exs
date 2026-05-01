defmodule Filament.Test.StubTest do
  use ExUnit.Case
  alias Filament.Test.Stub

  test "initial value returned via subscribe" do
    {:ok, stub} = Stub.start(fn _req -> 42 end)

    sub = %Filament.Observable.Subscriber{
      pid: self(),
      fiber_id: :test,
      slot_index: 0,
      project: &Function.identity/1
    }

    assert {:ok, 42} = Filament.Observable.subscribe(stub, nil, sub)
  end

  test "push delivers update to subscriber" do
    {:ok, stub} = Stub.start(fn _req -> 0 end)

    sub = %Filament.Observable.Subscriber{
      pid: self(),
      fiber_id: :fiber_a,
      slot_index: 1,
      project: &Function.identity/1
    }

    {:ok, _} = Filament.Observable.subscribe(stub, nil, sub)
    Stub.push(stub, 99)
    assert_receive {:filament_observable_update, :fiber_a, 1, 99}
  end

  test "push with projection — change-or-bust applies" do
    {:ok, stub} = Stub.start(fn _req -> 0 end)

    sub = %Filament.Observable.Subscriber{
      pid: self(),
      fiber_id: :fiber_b,
      slot_index: 0,
      project: fn n -> n > 5 end
    }

    {:ok, 0} = Filament.Observable.subscribe(stub, nil, sub)

    # First push always notifies because last_projected starts as :unset
    Stub.push(stub, 3)
    assert_receive {:filament_observable_update, :fiber_b, 0, false}

    # Push a value that doesn't change the projection
    Stub.push(stub, 4)
    refute_receive {:filament_observable_update, _, _, _}, 50

    # Push a value that changes the projection
    Stub.push(stub, 10)
    assert_receive {:filament_observable_update, :fiber_b, 0, true}
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
    # Set up a RenderContext with a stub registered for :my_server
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
      value = Filament.Hooks.use_observable(:my_server, nil, project: &Function.identity/1)
      assert value == :stub_value
    after
      Process.delete(:filament_render_context)
    end
  end
end
