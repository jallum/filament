defmodule Filament.Examples.CartTest do
  use ExUnit.Case, async: true
  import Filament.Test

  # ── Rung 1: Cart.State pure domain ──────────────────────────────────────────

  describe "Cart.State" do
    test "starts empty" do
      state = %Cart.State{}
      assert state.items == []
      assert state.total_cents == 0
      assert Cart.State.item_count(state) == 0
    end

    test "add_item/2 appends and updates total" do
      state = %Cart.State{}
      item = %Cart.Item{id: "a", name: "Widget", price_cents: 999, quantity: 1}
      state2 = Cart.State.add_item(state, item)
      assert Cart.State.item_count(state2) == 1
      assert state2.total_cents == 999
    end

    test "add_item/2 increments quantity for duplicate id" do
      state = %Cart.State{}
      item = %Cart.Item{id: "a", name: "Widget", price_cents: 500, quantity: 1}
      state2 = Cart.State.add_item(state, item)
      state3 = Cart.State.add_item(state2, item)
      assert Cart.State.item_count(state3) == 2
      assert state3.total_cents == 1000
      # still one distinct item
      assert length(state3.items) == 1
    end

    test "remove_item/2 removes item and adjusts total" do
      state = %Cart.State{}
      item = %Cart.Item{id: "b", name: "Gadget", price_cents: 2000, quantity: 1}
      state2 = Cart.State.add_item(state, item)
      state3 = Cart.State.remove_item(state2, "b")
      assert state3.items == []
      assert state3.total_cents == 0
    end

    test "remove_item/2 on nonexistent id is a no-op" do
      state = %Cart.State{}
      assert Cart.State.remove_item(state, "nonexistent") == state
    end

    test "item_count/1 sums quantities" do
      state = %Cart.State{
        items: [
          %Cart.Item{id: "a", name: "X", price_cents: 10, quantity: 3},
          %Cart.Item{id: "b", name: "Y", price_cents: 20, quantity: 2}
        ]
      }

      assert Cart.State.item_count(state) == 5
    end
  end

  # ── Rung 2: CartBadge isolated (stub observable) ──────────────────────────────

  describe "CartBadge (rung-2)" do
    test "renders item count from stub observable" do
      # Stub returns initial empty state. CartBadge applies count projection internally.
      {:ok, stub} = Filament.Test.Stub.start(fn _req -> %Cart.State{} end)

      {:ok, view} = mount(CartWeb.Components.CartBadge, %{server: stub})

      html = view.rendered_html
      # Badge renders empty (count=0 shows nothing due to conditional in template)
      assert html =~ "cart-badge"
      refute html =~ "data-count=\"1\""
    end

    test "badge updates when count changes" do
      {:ok, stub} = Filament.Test.Stub.start(fn _req -> %Cart.State{} end)

      {:ok, view} = mount(CartWeb.Components.CartBadge, %{server: stub})
      assert view.rendered_html =~ "data-count=\"0\""

      # Push a new state with one item
      new_state =
        Cart.State.add_item(
          %Cart.State{},
          %Cart.Item{id: "x", name: "Test", price_cents: 100, quantity: 1}
        )

      Filament.Test.Stub.push(stub, new_state)

      # Process the update message and re-render
      view = Filament.Test.update(view)
      assert view.rendered_html =~ "data-count=\"1\""
    end

    test "projection: badge does NOT receive update when count is unchanged" do
      # Core projection validation: count projection should suppress notifications
      # when projected value doesn't change
      {:ok, stub} = Filament.Test.Stub.start(fn _req -> %Cart.State{} end)

      # Subscribe with count projection
      sub = %Filament.Observable.Subscriber{
        pid: self(),
        fiber_id: :badge_test_fiber,
        slot_index: 0,
        project: fn state -> Cart.State.item_count(state) end
      }

      {:ok, _initial} = Filament.Observable.subscribe(stub, nil, sub)

      # First push: count 0 → 1
      state1 =
        Cart.State.add_item(
          %Cart.State{},
          %Cart.Item{id: "a", name: "A", price_cents: 100, quantity: 1}
        )

      Filament.Test.Stub.push(stub, state1)
      assert_receive {:filament_observable_update, :badge_test_fiber, 0, 1}, 500

      # Second push: same items, no count change - should NOT notify
      Filament.Test.Stub.push(stub, state1)
      refute_receive {:filament_observable_update, :badge_test_fiber, 0, _}, 100
    end
  end

  # ── Rung 3: CartView with real Cart.Server ───────────────────────────────────

  describe "CartView (rung-3, real Cart.Server)" do
    setup do
      {:ok, server} = Cart.Server.start_link([])
      {:ok, view} = mount(CartWeb.Components.CartView, %{server: server})
      %{server: server, view: view}
    end

    test "renders empty cart", %{view: view} do
      text = render_text(view)
      assert text =~ "Your Cart"
      assert text =~ "Total: 0 USD"
    end

    test "add_item updates rendered view", %{server: server, view: view} do
      Cart.Server.add_item(server, %Cart.Item{
        id: "w1",
        name: "Widget",
        price_cents: 999,
        quantity: 1
      })

      view = Filament.Test.update(view)
      assert render_text(view) =~ "Widget"
    end

    test "remove_item updates rendered view", %{server: server, view: view} do
      Cart.Server.add_item(server, %Cart.Item{
        id: "g1",
        name: "Gadget",
        price_cents: 500,
        quantity: 1
      })

      view = Filament.Test.update(view)
      assert render_text(view) =~ "Gadget"

      # Remove the item
      Cart.Server.remove_item(server, "g1")
      view = Filament.Test.update(view)
      refute render_text(view) =~ "Gadget"
    end

    test "eventually/2 retries until cart is updated asynchronously", %{
      server: server,
      view: view
    } do
      # Spawn an asynchronous mutation
      spawn(fn ->
        Process.sleep(50)

        Cart.Server.add_item(server, %Cart.Item{
          id: "async1",
          name: "AsyncItem",
          price_cents: 100,
          quantity: 1
        })
      end)

      # Store view ref for eventually callback
      view_ref = make_ref()
      Process.put(view_ref, view)

      Filament.Test.eventually(
        fn ->
          current = Process.get(view_ref)
          updated = Filament.Test.update(current)
          Process.put(view_ref, updated)
          String.contains?(render_text(updated), "AsyncItem")
        end,
        timeout: 500
      )
    end
  end

  # ── Rung 4: LiveView integration ─────────────────────────────────────────────
  # NOTE: CartLive requires CartWeb.Endpoint which is not configured in test env.
  # Skipping rung-4 tests for cart example.
end
