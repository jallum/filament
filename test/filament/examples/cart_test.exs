defmodule Filament.Examples.CartTest do
  use ExUnit.Case, async: true

  alias Cart.{Item, Server, State}
  alias CartWeb.Components.{CartBadge, CartView}

  test "Cart.State add_item and remove_item" do
    state = %State{}
    item = %Item{id: "a", name: "Widget", price_cents: 999}
    state = State.add_item(state, item)

    assert State.item_count(state) == 1
    assert state.total_cents == 999

    state = State.add_item(state, item)
    assert State.item_count(state) == 2
    assert state.total_cents == 1998

    state = State.remove_item(state, "a")
    assert State.item_count(state) == 0
    assert state.total_cents == 0
  end

  test "Cart.Server starts and returns state" do
    {:ok, server} = Server.start_link([])
    state = Server.get_state(server)
    assert state == %State{}
  end

  test "Cart.Server notifies observable subscribers on mutation" do
    {:ok, server} = Server.start_link([])

    test_pid = self()
    
    # Subscribe with projection
    subscriber = %Filament.Observable.Subscriber{
      pid: test_pid,
      fiber_id: :test_fiber,
      slot_index: 0,
      project: fn state -> State.item_count(state) end
    }
    
    # Subscribe returns the full state initially
    {:ok, %Cart.State{items: []}} = Filament.Observable.subscribe(server, nil, subscriber)

    # Add an item — should trigger notification with projected value.
    :ok = Server.add_item(server, %Item{id: "b", name: "Gadget", price_cents: 1500})

    # Expect an update message with the projected count.
    assert_receive {:filament_observable_update, :test_fiber, 0, 1}, 500
  end

  test "CartBadge component module exists" do
    assert {:module, CartBadge.CartBadge} = Code.ensure_loaded(CartBadge.CartBadge)
  end

  test "CartView component module exists" do
    assert {:module, CartView.CartView} = Code.ensure_loaded(CartView.CartView)
  end

  test "Cart.State remove_item handles non-existent item gracefully" do
    state = %State{}
    item = %Item{id: "a", name: "Widget", price_cents: 999}
    state = State.add_item(state, item)
    
    # Try to remove a non-existent item
    new_state = State.remove_item(state, "nonexistent")
    assert new_state == state  # Should return unchanged state
  end

  test "Cart.State calculates item_count correctly with multiple items" do
    state = %State{}
    item1 = %Item{id: "a", name: "Widget", price_cents: 999}
    item2 = %Item{id: "b", name: "Gadget", price_cents: 1500}
    
    state = State.add_item(state, item1)
    state = State.add_item(state, item1)  # Add same item again (quantity increments)
    state = State.add_item(state, item2)
    
    assert State.item_count(state) == 3  # 2 widgets + 1 gadget
  end
end
