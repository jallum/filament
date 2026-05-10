defmodule Filament.SubstrateBoundaryTest do
  @moduledoc """
  Phase 4: structural assertion that substrate modules don't pull
  `Phoenix.LiveView.*` deps. The substrate is the set of modules a
  non-web backend (TUI, native, etc.) would import — without it, the
  Core/Web split exists only by convention.

  This test inspects each substrate module's BEAM imports list and fails
  if any external call targets a forbidden Phoenix.LiveView.* module.
  Adding a Phoenix dep to a substrate module here surfaces immediately.

  ## Categorisation

  - **Pure substrate** — zero Phoenix.LiveView.* imports allowed. These are
    the modules a non-web backend can import unchanged.
  - **Substrate with display-protocol fallbacks** — `Phoenix.LiveView.Rendered`
    and `Phoenix.HTML.Safe` are allowed because they appear in compatibility
    paths (rendering Phoenix HEEx components embedded inside Filament
    trees, html-escaping scalars). These exceptions are explicit; a future
    pass can lift them.
  - **Web-specific** — full Phoenix integration. Not asserted on.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Rendered

  @pure_substrate [
    Filament.Cell,
    Filament.Component,
    Filament.Core,
    Filament.Defcomponent,
    Filament.Fiber,
    Filament.FiberTree,
    Filament.Hooks,
    Filament.KeyModifiers,
    Filament.Observable,
    Filament.Observable.GenServer,
    Filament.RenderContext,
    Filament.SigilF,
    Filament.VNode,
    Filament.VNodeCompiler,
    Filament.VNodeEngine
  ]

  @substrate_with_web_fallbacks [
    {Filament.Reconciler, [Rendered]},
    {Filament.Renderer, [Rendered, Phoenix.HTML.Safe]}
  ]

  defp module_imports(module) do
    {:module, ^module} = Code.ensure_loaded(module)
    beam_path = :code.which(module)

    case :beam_lib.chunks(beam_path, [:imports]) do
      {:ok, {^module, [imports: imports]}} ->
        imports |> Enum.map(fn {m, _f, _a} -> m end) |> Enum.uniq()

      _ ->
        []
    end
  end

  defp forbidden_imports(module, allowed) do
    module
    |> module_imports()
    |> Enum.filter(fn imported ->
      imported
      |> to_string()
      |> String.starts_with?("Elixir.Phoenix.LiveView")
    end)
    |> Enum.reject(&(&1 in allowed))
  end

  describe "pure substrate modules have no Phoenix.LiveView imports" do
    for mod <- @pure_substrate do
      @tag mod: mod
      test "#{inspect(mod)}", %{mod: mod} do
        forbidden = forbidden_imports(mod, [])

        assert forbidden == [],
               "#{inspect(mod)} (substrate) imports forbidden modules: #{inspect(forbidden)}"
      end
    end
  end

  describe "substrate-with-web-fallbacks: only the whitelisted modules are imported" do
    for {mod, allowed} <- @substrate_with_web_fallbacks do
      @tag mod: mod, allowed: allowed
      test "#{inspect(mod)}", %{mod: mod, allowed: allowed} do
        forbidden = forbidden_imports(mod, allowed)

        assert forbidden == [],
               """
               #{inspect(mod)} imports Phoenix.LiveView.* outside its allowlist.
               Allowed: #{inspect(allowed)}
               Forbidden: #{inspect(forbidden)}
               """
      end
    end
  end
end
