defmodule Cart.Application do
  @moduledoc """
  Cart application module for the Cart example.
  """
  use Application

  def start(_type, _args) do
    children = [
      # No additional processes needed for this example
    ]

    opts = [strategy: :one_for_one, name: Cart.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
