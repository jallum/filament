defmodule Cart.MixProject do
  use Mix.Project

  def project do
    [
      app: :cart,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Cart.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:filament, path: "../.."},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:bandit, "~> 1.0"}
    ]
  end
end
