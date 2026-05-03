defmodule Cart.Application do
  @moduledoc """
  Cart application module for the Cart example.
  """
  use Application

  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Cart.PubSub},
      {Registry, keys: :unique, name: Cart.Registry},
      {DynamicSupervisor, name: Cart.DynamicSupervisor, strategy: :one_for_one},
      CartWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Cart.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
