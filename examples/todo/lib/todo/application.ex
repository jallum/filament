defmodule Todo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Todo.PubSub},
      TodoWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Todo.Supervisor)
  end
end
