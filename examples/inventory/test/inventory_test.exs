defmodule Inventory.Test do
  use ExUnit.Case, async: true
  import Filament.Test

  # ── Rung 1: Inventory.Server domain ─────────────────────────────────────────

  describe "Inventory.Server" do
    setup do
      items = [
        %Inventory.Item{id: "item-a", name: "Widget", available: 2},
        %Inventory.Item{id: "item-b", name: "Gadget", available: 0}
      ]

      %{server: start_supervised!({Inventory.Server, items: items})}
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
      assert {:ok, _} = Filament.Hold.acquire(server, "item-a", self())
    end

    test "process death releases hold automatically", %{server: server} do
      assert Inventory.Server.get_item(server, "item-a").available == 2

      {:ok, _our_token} = Filament.Hold.acquire(server, "item-a", self())
      assert Inventory.Server.get_item(server, "item-a").available == 1

      parent = self()
      holder = spawn(fn ->
        {:ok, _token} = Filament.Hold.acquire(server, "item-a", self())
        send(parent, :acquired)
        receive do: (:die -> :ok)
      end)

      assert_receive :acquired, 500
      Process.exit(holder, :kill)
      Process.sleep(50)

      assert Inventory.Server.get_item(server, "item-a").available == 1
    end

    test "multiple holds on same item are tracked independently", %{server: server} do
      parent = self()

      holder1 = spawn(fn ->
        {:ok, _token} = Filament.Hold.acquire(server, "item-a", self())
        send(parent, {:h1, :acquired})
        receive do: (:stop -> :ok)
      end)

      holder2 = spawn(fn ->
        {:ok, _token} = Filament.Hold.acquire(server, "item-a", self())
        send(parent, {:h2, :acquired})
        receive do: (:stop -> :ok)
      end)

      assert_receive {:h1, :acquired}, 1000
      assert_receive {:h2, :acquired}, 1000

      assert {:error, :insufficient} = Filament.Hold.acquire(server, "item-a", self())

      Process.exit(holder1, :kill)
      Process.sleep(50)

      assert {:ok, _t3} = Filament.Hold.acquire(server, "item-a", self())
      Process.exit(holder2, :kill)
    end
  end

  # ── Rung 2: CheckoutLineItem component ───────────────────────────────────────

  describe "CheckoutLineItem (rung-2)" do
    test "renders out of stock when item has available=0" do
      server = start_supervised!({Inventory.Server, items: [
        %Inventory.Item{id: "oos", name: "Scarce", available: 0}
      ]})

      {:ok, view} = mount(InventoryWeb.Components.CheckoutLineItem, %{server: server, item_id: "oos"})
      assert render_text(view) =~ "Out of Stock"
    end

    test "renders checkout button when item is available" do
      server = start_supervised!({Inventory.Server, items: [
        %Inventory.Item{id: "avail", name: "In Stock Item", available: 3}
      ]})

      {:ok, view} = mount(InventoryWeb.Components.CheckoutLineItem, %{server: server, item_id: "avail"})
      text = render_text(view)
      refute text =~ "Out of Stock"
      assert text =~ "In Stock Item"
    end

    test "two components competing for last unit" do
      server = start_supervised!({Inventory.Server, items: [
        %Inventory.Item{id: "last", name: "LastUnit", available: 1}
      ]})

      {:ok, view1} = mount(InventoryWeb.Components.CheckoutLineItem, %{server: server, item_id: "last"})
      refute render_text(view1) =~ "Out of Stock"

      parent = self()
      spawn(fn ->
        {:ok, view2} = mount(InventoryWeb.Components.CheckoutLineItem, %{server: server, item_id: "last"})
        send(parent, {:view2_oos, String.contains?(render_text(view2), "Out of Stock")})
      end)

      assert_receive {:view2_oos, true}, 1000
    end
  end
end
