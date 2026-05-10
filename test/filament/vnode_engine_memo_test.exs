defmodule Filament.VNodeEngineMemoTest do
  @moduledoc """
  Phase 1.4.5/1.4.7 / regression note:

  `Filament.VNodeCompiler.assign_memos_vnode/2` is currently a passthrough
  (no `memo_at` wrapping). The naive per-call-site `{:t, N}` memo strategy
  was incorrect for closures inside `:for` comprehensions — a shared slot
  meant cache writes overwrote across iterations and re-renders served the
  wrong closure for every button. Porting the legacy comprehension-aware
  do_walk to vnode IR is tracked as a follow-up; until then closures
  rebuild each render. Behaviour is correct, perf is unoptimized.

  These tests are kept as documentation and re-enable points for when the
  comprehension-aware pass lands.
  """
  use ExUnit.Case, async: true

  describe "assign_memos_vnode/2 (passthrough)" do
    test "returns input AST unchanged" do
      ast =
        quote do
          Filament.Hooks.register_event_handler(fn -> set_val.("clicked") end)
        end

      assert Filament.VNodeCompiler.assign_memos_vnode(ast, [:set_val]) == ast
    end
  end

  describe "closure stability (deferred)" do
    @tag :skip
    test "stable closure produces identical fn reference across renders" do
      :ok
    end
  end
end
