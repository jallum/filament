defmodule Filament.Application do
  @moduledoc """
  Application supervisor for Filament.
  """

  use Supervisor

  @impl true
  def init(_args) do
    children = [
      # Add children here
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
