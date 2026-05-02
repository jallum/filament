defmodule Inventory.Application do
  @moduledoc """
  Inventory application module for the Inventory example.
  """
  use Application

  def start(_type, _args) do
    children = [
      # No additional processes needed for this example
    ]

    opts = [strategy: :one_for_one, name: Inventory.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
