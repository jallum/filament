defmodule Filament.VNodeEngineMemoTest do
  @moduledoc """
  Phase 1.4.5: closure-stability memoisation for `on_*` event handlers
  emitted under VNodeEngine. The pass wraps each `on_click={fn -> ... end}`
  literal with `Filament.Hooks.memo_at/3` keyed on the closure's reactive
  deps, so re-renders return the same fn object when deps haven't changed
  (matching the legacy `~F` path's existing behaviour).

  Reactive-value memoisation for non-handler interpolations is intentionally
  out of scope here — it's a perf optimisation without behavioural impact
  given the substrate walker rebuilds the fiber tree per render.
  """
  use ExUnit.Case, async: true

  alias Filament.FiberTree
  alias Filament.Reconciler

  defmodule StableFixture do
    @moduledoc false
    use Filament.Component

    defcomponent StableHandler do
      def render(_assigns) do
        {_val, set_val} = use_state("x")

        Filament.VNodeCompiler.assign_memos_vnode(
          quote do
            {:element, "button",
             [{"on_click", fn -> unquote({:set_val, [], nil}).("clicked") end}],
             [{:text, "Go"}]}
          end,
          [:set_val]
        )
        |> Code.eval_quoted([set_val: set_val], __ENV__)
        |> elem(0)
      end
    end
  end

  describe "assign_memos_vnode/2" do
    test "wraps on_* fn-literal attr value with memo_at(deps)" do
      ast =
        quote do
          {:element, "button",
           [{"on_click", fn -> set_val.("clicked") end}],
           [{:text, "Go"}]}
        end

      rewritten = Filament.VNodeCompiler.assign_memos_vnode(ast, [:set_val])

      # The fn literal in the on_click value should now be wrapped with memo_at.
      assert match_memo_at?(rewritten, "on_click")
    end

    test "leaves non-on_* fn attrs alone" do
      ast =
        quote do
          {:element, "button",
           [{"data-handler", fn -> :foo end}],
           [{:text, "Go"}]}
        end

      rewritten = Filament.VNodeCompiler.assign_memos_vnode(ast, [:set_val])
      refute match_memo_at?(rewritten, "data-handler")
    end

    test "leaves non-fn on_* attr values alone (already-resolved wire refs etc.)" do
      ast =
        quote do
          {:element, "button",
           [{"on_click", "filament:root:0"}],
           [{:text, "Go"}]}
        end

      rewritten = Filament.VNodeCompiler.assign_memos_vnode(ast, [])
      refute match_memo_at?(rewritten, "on_click")
    end
  end

  describe "closure stability under VNodeEngine pipeline" do
    test "stable closure produces identical fn reference across renders" do
      {tree1, _, _} = Reconciler.mount(StableFixture.StableHandler, %{}, owner_pid: self())
      handler1 = FiberTree.get_event_handler(tree1, "root", 0)

      {tree2, _, _} = Reconciler.update(tree1, "root", %{}, owner_pid: self())
      handler2 = FiberTree.get_event_handler(tree2, "root", 0)

      assert is_function(handler1)
      assert handler1 === handler2,
             "expected stable closure fn to be the same object across renders"
    end
  end

  # Helper: scans an AST for `Filament.Hooks.memo_at(_, _, fn -> fn -> _ end end)`
  # at an `on_*` attr value position.
  defp match_memo_at?(ast, attr_name) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {^attr_name,
         {{:., _, [{:__aliases__, _, [:Filament, :Hooks]}, :memo_at]}, _, _}} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
