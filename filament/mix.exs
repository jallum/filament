defmodule Filament.MixProject do
  use Mix.Project

  def project do
    [
      app: :filament,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.36", only: [:dev, :docs], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Filament",
      logo: ".tmp/logo.png",
      extras: [
        "guides/Getting Started.md",
        "guides/Observables.md",
        "guides/Resource Holds.md",
        "guides/Migration Guide.md"
      ]
    ]
  end

  defp package do
    [
      description: "Filament is a Phoenix LiveView component library",
      licenses: ["Apache-2.0"],
      links: %{}
    ]
  end
end
