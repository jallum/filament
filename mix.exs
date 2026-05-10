defmodule Filament.MixProject do
  use Mix.Project

  def project do
    [
      app: :filament,
      version: "0.4.1",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix]],
      docs: docs(),
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(Mix.env())
    ]
  end

  # Include test/support (fixtures) and examples for compile verification in test env
  defp elixirc_paths(:test),
    do: [
      "lib",
      "test/support",
      "examples/todo/lib",
      "examples/cart/lib",
      "examples/inventory/lib",
      "examples/collaboration/lib"
    ]

  defp elixirc_paths(_), do: ["lib"]

  defp test_paths(:test),
    do: ["test", "examples/cart/test", "examples/collaboration/test", "examples/inventory/test", "examples/todo/test"]

  defp test_paths(_), do: ["test"]

  # Configure test paths to avoid ExUnit warnings for fixture/support files
  def cli do
    [
      preferred_cli_env: [test: :test]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :phoenix_live_view]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Development and quality tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.36", only: [:dev, :docs], runtime: false},
      {:styler, "~> 1.4", only: [:dev, :test], runtime: false},
      # HTML parsing — used by Filament.Test; consumers must add {:floki, ">= 0.0.0", only: :test}
      {:floki, ">= 0.0.0", optional: true},
      # Phoenix LiveView dependencies for runtime and testing
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:plug, "~> 1.16"},
      {:plug_cowboy, "~> 2.7", only: :test}
    ]
  end

  defp docs do
    [
      main: "Filament",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "guides/getting-started.md",
        "guides/observables.md",
        "guides/cells.md",
        "guides/events.md",
        "guides/hooks.md",
        "guides/testing.md",
        "guides/module-organization.md",
        "guides/migration-guide.md"
      ],
      groups_for_modules: [
        Components: [Filament.Component, Filament.Defcomponent, Filament.SigilF],
        Hooks: [Filament.Hooks],
        Observables: [Filament.Observable, Filament.Observable.GenServer],
        Cells: [Filament.Cell],
        Core: [Filament.Core],
        LiveView: [Filament.LiveView]
      ]
    ]
  end

  defp package do
    [
      description: "JSX-like LiveView components — events as closures, state as hooks, servers as observables",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/jallum/filament"}
    ]
  end
end
