defmodule Filament.Examples.InventoryTest do
  use ExUnit.Case, async: true

  alias Inventory.{Item, Server}

  defp start_server(items) do
    {:ok, server} = Server.start_link(items: items)
    server
  end

  test "acquire hold decrements available" do
    item = %Item{id: "x", name: "X", available: 2}
    server = start_server([item])

    # Acquire via direct Hold API for testing
    assert {:ok, _token} = Filament.Hold.acquire(server, "x", self())

    after_first = Server.get_item(server, "x")
    assert after_first.available == 1
  end

  test "acquire returns {:error, :insufficient} when none available" do
    item = %Item{id: "y", name: "Y", available: 1}
    server = start_server([item])

    assert {:ok, _token} = Filament.Hold.acquire(server, "y", self())
    assert {:error, :insufficient} = Filament.Hold.acquire(server, "y", self())
  end

  test "process death releases hold and restores availability" do
    item = %Item{id: "z", name: "Z", available: 1}
    server = start_server([item])

    # Acquire from a spawned process so we can kill it.
    parent = self()
    holder = spawn(fn ->
      result = Filament.Hold.acquire(server, "z", self())
      send(parent, {:acquired, result})
      receive do: (:die -> :ok)
    end)

    assert_receive {:acquired, {:ok, _token}}, 500

    # Verify hold is active — available should be 0.
    assert Server.get_item(server, "z").available == 0

    # Kill the holder — :DOWN should trigger handle_release.
    Process.exit(holder, :kill)
    Process.sleep(50)  # give the monitor time to fire

    # Available should be restored.
    assert Server.get_item(server, "z").available == 1
  end

  test "CheckoutLineItem component exists" do
    assert {:module, InventoryWeb.Components.CheckoutLineItem} = Code.ensure_loaded(InventoryWeb.Components.CheckoutLineItem)
  end

  test "handle_acquire returns error for unknown item" do
    server = start_server([])
    assert {:error, :not_found} = Filament.Hold.acquire(server, "unknown", self())
  end

  test "multiple independent holds on different items" do
    item1 = %Item{id: "a", name: "A", available: 2}
    item2 = %Item{id: "b", name: "B", available: 3}
    server = start_server([item1, item2])

    assert {:ok, _token1} = Filament.Hold.acquire(server, "a", self())
    assert {:ok, _token2} = Filament.Hold.acquire(server, "b", self())

    assert Server.get_item(server, "a").available == 1
    assert Server.get_item(server, "b").available == 2
  end
end
