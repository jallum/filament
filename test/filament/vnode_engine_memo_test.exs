defmodule Filament.VNodeEngineMemoTest do
  @moduledoc """
  Phase 1.4.5/1.4.7: closure-stability memoisation for `on_*` event handlers
  emitted under the VNodeEngine pipeline. Codegen rewrites
  `<button on_click={fn}>` to a `phx-click` attr whose value is
  `"filament:" <> Filament.Hooks.register_event_handler(fn)`. The memoisation
  pass then wraps the fn arg of `register_event_handler/1` with
  `Filament.Hooks.memo_at/3` keyed on the closure's reactive deps, so
  re-renders return the same fn object when deps haven't changed.
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
        ~F"<button on_click={fn -> set_val.(\"clicked\") end}>Go</button>"
      end
    end
  end

  describe "assign_memos_vnode/2" do
    test "wraps fn arg of register_event_handler/1 with memo_at(deps)" do
      ast =
        quote do
          Filament.Hooks.register_event_handler(fn -> set_val.("clicked") end)
        end

      rewritten = Filament.VNodeCompiler.assign_memos_vnode(ast, [:set_val])
      assert memo_at_around_register?(rewritten)
    end

    test "leaves bare register_event_handler(var) alone (no fn literal)" do
      # When the handler is a var ref (e.g., a prop passed in), there's no
      # closure literal to memoise — the handler's identity is already stable
      # at the call site.
      ast =
        quote do
          Filament.Hooks.register_event_handler(handler)
        end

      rewritten = Filament.VNodeCompiler.assign_memos_vnode(ast, [:handler])
      refute memo_at_around_register?(rewritten)
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

  # Recognises a memo_at(_, _, fn -> fn -> _ end end) wrapping inside a
  # register_event_handler/1 call.
  defp memo_at_around_register?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Filament, :Hooks]}, :register_event_handler]}, _,
         [{{:., _, [{:__aliases__, _, [:Filament, :Hooks]}, :memo_at]}, _, _}]} = node,
        _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
