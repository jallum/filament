defmodule Inventory.MixProject do
  use Mix.Project

  def project do
    [
      app: :inventory,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Inventory.Application, []}
    ]
  end

  defp deps do
    [
      {:filament, path: "../.."},
      {:bandit, "~> 1.0"}
    ]
  end
end
