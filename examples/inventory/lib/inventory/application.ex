defmodule Inventory.Application do
  use Application

  def start(_type, _args) do
    demo_items = [
      %Inventory.Item{id: "apple", name: "Apple", available: 2},
      %Inventory.Item{id: "banana", name: "Banana", available: 1},
      %Inventory.Item{id: "cherry", name: "Cherry (bag)", available: 0}
    ]

    children = [
      {Phoenix.PubSub, name: Inventory.PubSub},
      {Inventory.Server, items: demo_items, name: Inventory.Server},
      InventoryWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Inventory.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
