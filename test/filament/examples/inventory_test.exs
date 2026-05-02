defmodule Filament.Examples.InventoryTest do
  use ExUnit.Case, async: true
  import Filament.Test

  # ── Rung 1: Inventory.Server domain ─────────────────────────────────────────

  describe "Inventory.Server" do
    setup do
      items = [
        %Inventory.Item{id: "item-a", name: "Widget", available: 2},
        %Inventory.Item{id: "item-b", name: "Gadget", available: 0}
      ]

      {:ok, server} = Inventory.Server.start_link(items: items)
      %{server: server}
    end

    test "acquire/3 decrements available and returns token", %{server: server} do
      assert {:ok, token} = Filament.Hold.acquire(server, "item-a", self())
      assert is_tuple(token)
    end

    test "acquire/3 returns {:error, :insufficient} when available=0", %{server: server} do
      assert {:error, :insufficient} = Filament.Hold.acquire(server, "item-b", self())
    end

    test "acquire/3 returns {:error, :not_found} for unknown item", %{server: server} do
      assert {:error, :not_found} = Filament.Hold.acquire(server, "nonexistent", self())
    end

    test "release/2 restores availability", %{server: server} do
      {:ok, token} = Filament.Hold.acquire(server, "item-a", self())
      :ok = Filament.Hold.release(server, token)

      # Re-acquire to confirm availability was restored
      assert {:ok, _token2} = Filament.Hold.acquire(server, "item-a", self())
    end

    test "process death releases hold automatically", %{server: server} do
      # Confirm initial availability = 2 for "item-a".
      item = Inventory.Server.get_item(server, "item-a")
      assert item.available == 2

      # Acquire one unit
      {:ok, _our_token} = Filament.Hold.acquire(server, "item-a", self())
      item = Inventory.Server.get_item(server, "item-a")
      assert item.available == 1

      # Spawn a second holder
      parent = self()

      holder =
        spawn(fn ->
          {:ok, _token} = Filament.Hold.acquire(server, "item-a", self())
          send(parent, :acquired)
          receive do: (:die -> :ok)
        end)

      assert_receive :acquired, 500

      # Now kill the holder — :DOWN should trigger handle_release
      Process.exit(holder, :kill)
      Process.sleep(50)

      # Available should be restored to 1 (we still hold one)
      item = Inventory.Server.get_item(server, "item-a")
      assert item.available == 1
    end

    test "multiple holds on same item are tracked independently", %{server: server} do
      parent = self()

      holder1 =
        spawn(fn ->
          {:ok, _token} = Filament.Hold.acquire(server, "item-a", self())
          send(parent, {:h1, :acquired})
          receive do: (:stop -> :ok)
        end)

      holder2 =
        spawn(fn ->
          {:ok, _token} = Filament.Hold.acquire(server, "item-a", self())
          send(parent, {:h2, :acquired})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:h1, :acquired}, 1000
      assert_receive {:h2, :acquired}, 1000

      # Both slots taken (available=0). Third acquire fails.
      assert {:error, :insufficient} = Filament.Hold.acquire(server, "item-a", self())

      # Kill holder1, one slot freed
      Process.exit(holder1, :kill)
      Process.sleep(50)

      assert {:ok, _t3} = Filament.Hold.acquire(server, "item-a", self())

      # Clean up holder2
      Process.exit(holder2, :kill)
    end
  end

  # ── Rung 2: CheckoutLineItem component isolation ─────────────────────────────

  describe "CheckoutLineItem (rung-2)" do
    test "renders out of stock when item has available=0" do
      items = [
        %Inventory.Item{id: "oos", name: "Scarce", available: 0}
      ]

      {:ok, server} = Inventory.Server.start_link(items: items)

      {:ok, view} =
        mount(InventoryWeb.Components.CheckoutLineItem, %{
          server: server,
          item_id: "oos"
        })

      text = render_text(view)
      assert text =~ "Out of Stock"
    end

    test "renders checkout button when item is available" do
      items = [
        %Inventory.Item{id: "avail", name: "In Stock Item", available: 3}
      ]

      {:ok, server} = Inventory.Server.start_link(items: items)

      {:ok, view} =
        mount(InventoryWeb.Components.CheckoutLineItem, %{
          server: server,
          item_id: "avail"
        })

      text = render_text(view)
      refute text =~ "Out of Stock"
      assert text =~ "In Stock Item"
    end

    test "two components competing for last unit" do
      items = [
        %Inventory.Item{id: "last", name: "LastUnit", available: 1}
      ]

      {:ok, server} = Inventory.Server.start_link(items: items)

      {:ok, view1} =
        mount(InventoryWeb.Components.CheckoutLineItem, %{
          server: server,
          item_id: "last"
        })

      # view1 acquired the only unit

      # view2 in a separate process should see out of stock
      parent = self()

      spawn(fn ->
        {:ok, view2} =
          mount(InventoryWeb.Components.CheckoutLineItem, %{
            server: server,
            item_id: "last"
          })

        text = render_text(view2)
        result = String.contains?(text, "Out of Stock")
        send(parent, {:view2_result, result})
      end)

      assert_receive {:view2_result, true}, 1000

      # view1 should still show held state
      text1 = render_text(view1)
      refute text1 =~ "Out of Stock"
    end
  end
end
