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

    test "hold decrements available", %{server: server} do
      assert :ok = GenServer.call(server, {:filament_hold, "item-a", 1, self()})
      assert Inventory.Server.get_item(server, "item-a").available == 1
    end

    test "hold returns {:error, :insufficient} when available=0", %{server: server} do
      assert {:error, :insufficient} =
               GenServer.call(server, {:filament_hold, "item-b", 1, self()})
    end

    test "hold returns {:error, :not_found} for unknown item", %{server: server} do
      assert {:error, :not_found} =
               GenServer.call(server, {:filament_hold, "nonexistent", 1, self()})
    end

    test "release_qty restores availability", %{server: server} do
      :ok = GenServer.call(server, {:filament_hold, "item-a", 1, self()})
      GenServer.cast(server, {:filament_release_qty, "item-a", 1, self()})
      Process.sleep(20)
      assert Inventory.Server.get_item(server, "item-a").available == 2
    end

    test "process death releases hold automatically", %{server: server} do
      parent = self()

      holder =
        spawn(fn ->
          sub = %Filament.Observable.Subscriber{
            pid: self(),
            fiber_id: :holder_fiber,
            slot_index: 0,
            project: &Function.identity/1
          }

          {:ok, _} = Filament.Observable.subscribe(server, "item-a", sub)
          :ok = GenServer.call(server, {:filament_hold, "item-a", 1, self()})
          send(parent, :acquired)
          receive do: (:die -> :ok)
        end)

      assert_receive :acquired, 500
      assert Inventory.Server.get_item(server, "item-a").available == 1

      Process.exit(holder, :kill)
      Process.sleep(50)

      assert Inventory.Server.get_item(server, "item-a").available == 2
    end

    test "multiple holds on same item tracked independently", %{server: server} do
      parent = self()

      for i <- [1, 2] do
        spawn(fn ->
          sub = %Filament.Observable.Subscriber{
            pid: self(),
            fiber_id: :"holder_#{i}",
            slot_index: 0,
            project: &Function.identity/1
          }

          {:ok, _} = Filament.Observable.subscribe(server, "item-a", sub)
          :ok = GenServer.call(server, {:filament_hold, "item-a", 1, self()})
          send(parent, {:"h#{i}", :acquired})
          receive do: (:stop -> :ok)
        end)
      end

      assert_receive {:h1, :acquired}, 1000
      assert_receive {:h2, :acquired}, 1000

      assert {:error, :insufficient} =
               GenServer.call(server, {:filament_hold, "item-a", 1, self()})
    end
  end

  # ── Rung 2: InventoryItem component ──────────────────────────────────────────

  describe "InventoryItem (rung-2)" do
    test "renders out of stock when item has available=0" do
      server =
        start_supervised!(
          {Inventory.Server, items: [%Inventory.Item{id: "oos", name: "Scarce", available: 0}]}
        )

      {:ok, view} =
        mount(InventoryWeb.Components.InventoryItem, %{server: server, item_id: "oos"})

      assert render_text(view) =~ "Out of Stock"
    end

    test "renders hold button when item is available" do
      server =
        start_supervised!(
          {Inventory.Server,
           items: [%Inventory.Item{id: "avail", name: "In Stock Item", available: 3}]}
        )

      {:ok, view} =
        mount(InventoryWeb.Components.InventoryItem, %{server: server, item_id: "avail"})

      text = render_text(view)
      refute text =~ "Out of Stock"
      assert text =~ "In Stock Item"
    end

    test "second component sees Out of Stock once first has acquired a hold" do
      server =
        start_supervised!(
          {Inventory.Server,
           items: [%Inventory.Item{id: "last", name: "LastUnit", available: 1}]}
        )

      parent = self()

      # Spawn a subscriber that acquires the hold, then waits
      holder =
        spawn(fn ->
          sub = %Filament.Observable.Subscriber{
            pid: self(),
            fiber_id: :holder,
            slot_index: 0,
            project: &Function.identity/1
          }

          {:ok, _} = Filament.Observable.subscribe(server, "last", sub)
          :ok = GenServer.call(server, {:filament_hold, "last", 1, self()})
          send(parent, :held)
          receive do: (:stop -> :ok)
        end)

      assert_receive :held, 500

      # A second component subscribing now should see 0 available → Out of Stock
      {:ok, view2} =
        mount(InventoryWeb.Components.InventoryItem, %{server: server, item_id: "last"})

      assert render_text(view2) =~ "Out of Stock"

      send(holder, :stop)
    end
  end
end
