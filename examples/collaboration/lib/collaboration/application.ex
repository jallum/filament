defmodule Collaboration.Application do
  @moduledoc """
  Collaboration application module.
  """
  use Application

  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Collaboration.PubSub},
      {Registry, keys: :unique, name: Collaboration.Registry},
      # Start the demo document server supervised — independent of any LiveView process
      {Collaboration.DocumentServer, doc_id: "demo-doc"},
      CollaborationWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Collaboration.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
