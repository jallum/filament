defmodule Filament.VNodeEngineMemoTest do
  @moduledoc """
  Phase 1.5.1: comprehension-aware closure-stability memoisation.

  `Filament.VNodeCompiler.wrap_comprehensions_with_memo/2` detects `:for`
  AST containing `Filament.Hooks.register_event_handler` and wraps the
  whole for-expression with `memo_at({:t, N}, outer_vars, fn -> for end)`.
  When outer-scope deps haven't changed, the cached list of per-iteration
  vnodes is reused and the previously-registered handlers are replayed
  into the current render's event-handler map. Closures keep their
  identity across renders; per-iteration var capture stays correct.
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
        ~F'<button on_click={fn -> set_val.("clicked") end}>Go</button>'
      end
    end
  end

  defmodule LoopFixture do
    @moduledoc false
    use Filament.Component

    defcomponent ForLoop do
      prop(:items, :list, required: true)

      def render(%{items: items}) do
        {_last, set_last} = use_state(nil)

        ~F"""
        <ul>
          {for item <- items do}
            <li><a on_click={fn -> set_last.(item) end}>{item}</a></li>
          {end}
        </ul>
        """
      end
    end
  end

  describe "single on_* closure stability" do
    test "stable closure produces identical fn reference across renders" do
      {tree1, _, _} = Reconciler.mount(StableFixture.StableHandler, %{}, owner_pid: self())
      handler1 = FiberTree.get_event_handler(tree1, "root", 0)

      {tree2, _, _} = Reconciler.update(tree1, "root", %{}, owner_pid: self())
      handler2 = FiberTree.get_event_handler(tree2, "root", 0)

      assert is_function(handler1)
      assert handler1 === handler2
    end
  end

  describe "for-loop closure stability" do
    test "closures stable across renders when items unchanged" do
      items = [:a, :b, :c]
      {tree1, _, _} = Reconciler.mount(LoopFixture.ForLoop, %{items: items}, owner_pid: self())

      [h1_0, h1_1, h1_2] =
        Enum.map(0..2, &FiberTree.get_event_handler(tree1, "root", &1))

      {tree2, _, _} = Reconciler.update(tree1, "root", %{items: items}, owner_pid: self())

      [h2_0, h2_1, h2_2] =
        Enum.map(0..2, &FiberTree.get_event_handler(tree2, "root", &1))

      assert h1_0 === h2_0, "iter 0 closure should be reused"
      assert h1_1 === h2_1, "iter 1 closure should be reused"
      assert h1_2 === h2_2, "iter 2 closure should be reused"
    end

    test "per-iteration var capture is correct across re-renders (1.5 cart regression)" do
      items = [:apple, :banana, :cherry]
      {tree1, _, _} = Reconciler.mount(LoopFixture.ForLoop, %{items: items}, owner_pid: self())

      h_apple = FiberTree.get_event_handler(tree1, "root", 0)
      h_banana = FiberTree.get_event_handler(tree1, "root", 1)
      h_cherry = FiberTree.get_event_handler(tree1, "root", 2)

      h_apple.()
      assert_received {:filament_set_state, _, _, :apple}

      h_banana.()
      assert_received {:filament_set_state, _, _, :banana}

      h_cherry.()
      assert_received {:filament_set_state, _, _, :cherry}

      # Re-render — handlers should still fire with the right captured item.
      {tree2, _, _} = Reconciler.update(tree1, "root", %{items: items}, owner_pid: self())

      FiberTree.get_event_handler(tree2, "root", 1).()
      assert_received {:filament_set_state, _, _, :banana},
                      "iter 1 must still capture :banana, not :cherry (1.4.7 bug regression)"
    end

    test "growing items list keeps prior closures stable, mints new ones" do
      # BEAM hash-conses fn objects whose captures are structurally equal, so
      # iterations whose captured value is unchanged return the same fn —
      # no explicit memoisation needed.
      {tree1, _, _} =
        Reconciler.mount(LoopFixture.ForLoop, %{items: [:a, :b]}, owner_pid: self())

      h1_0 = FiberTree.get_event_handler(tree1, "root", 0)

      {tree2, _, _} =
        Reconciler.update(tree1, "root", %{items: [:a, :b, :c]}, owner_pid: self())

      h2_0 = FiberTree.get_event_handler(tree2, "root", 0)
      h2_2 = FiberTree.get_event_handler(tree2, "root", 2)

      assert h1_0 === h2_0, "iter 0 closure (captures :a) should still be identity-stable"
      assert is_function(h2_2), "third iteration handler exists after items grow"
    end

    test "iter-0 closure rebuilds when items[0] changes" do
      {tree1, _, _} =
        Reconciler.mount(LoopFixture.ForLoop, %{items: [:apple, :banana]}, owner_pid: self())

      h1_0 = FiberTree.get_event_handler(tree1, "root", 0)

      {tree2, _, _} =
        Reconciler.update(tree1, "root", %{items: [:avocado, :banana]}, owner_pid: self())

      h2_0 = FiberTree.get_event_handler(tree2, "root", 0)
      h2_1 = FiberTree.get_event_handler(tree2, "root", 1)

      refute h1_0 === h2_0, "iter 0 captured :apple before, :avocado now → different fn"

      h2_0.()
      assert_received {:filament_set_state, _, _, :avocado},
                      "new iter 0 handler must capture the new item"

      h2_1.()
      assert_received {:filament_set_state, _, _, :banana},
                      "iter 1 (unchanged) must still fire :banana"
    end
  end
end
