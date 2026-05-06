defmodule Filament.VNodeCompilerTest do
  use ExUnit.Case, async: true

  alias Filament.FiberTree
  alias Filament.Reconciler
  alias Phoenix.HTML.Safe

  describe "assigns-free render" do
    test "render without assigns in scope compiles and renders correctly" do
      defmodule AssignsFreeComp do
        @moduledoc false
        use Filament.Component

        defcomponent AssignsFree do
          def render(%{text: text, count: count}) do
            ~F"""
            <div class="item">
              <span>{text}</span>
              <em>{count}</em>
            </div>
            """
          end
        end
      end

      {_tree, rendered, _} =
        Reconciler.mount(AssignsFreeComp.AssignsFree, %{text: "hello", count: 3}, owner_pid: self())

      html = rendered |> Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "hello"
      assert html =~ "3"
    end
  end

  describe "warning suppression" do
    test "compiling template with lexically-bound variable produces no warnings" do
      # IO.warn (used by TagEngine's maybe_warn_taint) writes to stderr, not Logger.
      # CaptureLog would miss it. Force fresh compilation inside capture_io(:stderr)
      # so the warning — if emitted — is caught during macro expansion.
      n = System.unique_integer([:positive])

      src = """
      defmodule WarningDynamic#{n} do
        use Filament.Component
        defcomponent WT do
          def render(assigns) do
            lock_holder_name = "alice"
            ~F"<div>{lock_holder_name}</div>"
          end
        end
      end
      """

      warnings = ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(src) end)

      refute warnings =~ "you are accessing the variable"
      refute warnings =~ "inside a LiveView template"
    end
  end

  describe "wire-ref stability" do
    test "multiple handlers keep stable slot indices across re-renders" do
      defmodule MultiHandlerComp do
        @moduledoc false
        use Filament.Component

        defcomponent MultiHandler do
          def render(_assigns) do
            {count, set_count} = use_state(0)

            ~F"""
            <div>
              <button on_click={fn -> set_count.(count + 1) end}>A</button>
              <button on_click={fn -> :action2 end}>B</button>
            </div>
            """
          end
        end
      end

      {tree1, _, _} =
        Reconciler.mount(MultiHandlerComp.MultiHandler, %{}, owner_pid: self())

      h1_slot0 = FiberTree.get_event_handler(tree1, "root", 0)
      h1_slot1 = FiberTree.get_event_handler(tree1, "root", 1)
      assert is_function(h1_slot0) and is_function(h1_slot1)
      refute h1_slot0 === h1_slot1, "distinct handlers must occupy distinct slots"

      # Advance count: use_state is hook slot 0 — change count 0 → 1
      updated =
        FiberTree.update_hook_slot(tree1, "root", 0, fn {_, setter} -> {1, setter} end)

      {tree2, _, _} = Reconciler.update(updated, "root", %{}, owner_pid: self())

      h2_slot0 = FiberTree.get_event_handler(tree2, "root", 0)
      h2_slot1 = FiberTree.get_event_handler(tree2, "root", 1)

      # Slot 1 is a stable closure (no reactive deps) — same fn object
      assert h1_slot1 === h2_slot1, "stable handler slot must be identical across renders"
      # Slot 0 captures count which changed — new fn, but SAME slot index
      assert is_function(h2_slot0), "handler at slot 0 must still be a function after re-render"
      refute h1_slot0 === h2_slot0, "reactive handler must change when dep changes"
    end
  end

  describe "stable closure fn identity" do
    # Closure capturing only a stable setter (set_val doesn't change between renders)
    # → memo_at({:t, N}, [set_val], fn -> closure end) → same fn object every render.
    test "stable closure produces identical fn reference across renders" do
      defmodule StableClosureComp do
        @moduledoc false
        use Filament.Component

        defcomponent StableClosure do
          def render(_assigns) do
            {_val, set_val} = use_state("x")
            ~F'<button on_click={fn -> set_val.("clicked") end}>Go</button>'
          end
        end
      end

      {tree1, _, _} = Reconciler.mount(StableClosureComp.StableClosure, %{}, owner_pid: self())
      handler1 = FiberTree.get_event_handler(tree1, "root", 0)

      {tree2, _, _} = Reconciler.update(tree1, "root", %{}, owner_pid: self())
      handler2 = FiberTree.get_event_handler(tree2, "root", 0)

      assert is_function(handler1), "expected event handler to be a function"

      assert handler1 === handler2,
             "expected stable closure fn to be the same object across renders"
    end
  end

  describe "reactive closure fn identity" do
    # Closure capturing a reactive var (count in the template) → deps = [count].
    # When count changes, memo_at invalidates and produces a new fn.
    test "reactive closure produces new fn reference when dep changes" do
      defmodule ReactiveClosureComp do
        @moduledoc false
        use Filament.Component

        defcomponent ReactiveClosure do
          def render(_assigns) do
            {count, set_count} = use_state(0)
            ~F'<button on_click={fn -> set_count.(count + 1) end}>+</button>'
          end
        end
      end

      {tree1, _, _} =
        Reconciler.mount(ReactiveClosureComp.ReactiveClosure, %{}, owner_pid: self())

      handler1 = FiberTree.get_event_handler(tree1, "root", 0)

      # Advance count: slot 0 = {value, setter}, change value 0 → 1
      updated =
        FiberTree.update_hook_slot(tree1, "root", 0, fn {_, setter} -> {1, setter} end)

      {tree2, _, _} = Reconciler.update(updated, "root", %{}, owner_pid: self())
      handler2 = FiberTree.get_event_handler(tree2, "root", 0)

      assert is_function(handler2), "expected event handler to be a function"

      refute handler1 === handler2,
             "expected reactive closure to produce a new fn when count changed"
    end

    test "reactive closure reuses fn reference when dep unchanged" do
      defmodule ReactiveClosureStableComp do
        @moduledoc false
        use Filament.Component

        defcomponent ReactiveClosureStable do
          def render(_assigns) do
            {count, set_count} = use_state(0)
            ~F'<button on_click={fn -> set_count.(count + 1) end}>+</button>'
          end
        end
      end

      {tree1, _, _} =
        Reconciler.mount(ReactiveClosureStableComp.ReactiveClosureStable, %{}, owner_pid: self())

      handler1 = FiberTree.get_event_handler(tree1, "root", 0)

      # Re-render with no state change — count is still 0
      {tree2, _, _} = Reconciler.update(tree1, "root", %{}, owner_pid: self())
      handler2 = FiberTree.get_event_handler(tree2, "root", 0)

      assert handler1 === handler2,
             "expected reactive closure fn to be reused when count did not change"
    end
  end

  describe "comprehension memoization" do
    test "for-loop with handlers reuses result when outer-scope deps unchanged" do
      defmodule CompMemoComp do
        @moduledoc false
        use Filament.Component

        defcomponent CompMemo do
          def render(assigns) do
            {_sel, set_sel} = use_state(:all)

            ~F"""
            <ul>
              {for {val, label} <- assigns.items do}
                <li><a on_click={fn -> set_sel.(val) end}>{label}</a></li>
              {end}
            </ul>
            """
          end
        end
      end

      items = [{:all, "All"}, {:active, "Active"}, {:done, "Done"}]

      {tree1, _rendered1, _} =
        Reconciler.mount(CompMemoComp.CompMemo, %{items: items}, owner_pid: self())

      h1_slot0 = FiberTree.get_event_handler(tree1, "root", 0)
      h1_slot1 = FiberTree.get_event_handler(tree1, "root", 1)
      h1_slot2 = FiberTree.get_event_handler(tree1, "root", 2)

      assert is_function(h1_slot0)
      assert is_function(h1_slot1)
      assert is_function(h1_slot2)

      # Re-render with same items — comprehension memo deps unchanged, handlers reused
      {tree2, _rendered2, _} =
        Reconciler.update(tree1, "root", %{items: items}, owner_pid: self())

      h2_slot0 = FiberTree.get_event_handler(tree2, "root", 0)
      h2_slot1 = FiberTree.get_event_handler(tree2, "root", 1)
      h2_slot2 = FiberTree.get_event_handler(tree2, "root", 2)

      assert h1_slot0 === h2_slot0, "handler 0 should be reused when deps stable"
      assert h1_slot1 === h2_slot1, "handler 1 should be reused when deps stable"
      assert h1_slot2 === h2_slot2, "handler 2 should be reused when deps stable"
    end

    test "for-loop with handlers recomputes when items prop changes" do
      defmodule CompMemoRebuildComp do
        @moduledoc false
        use Filament.Component

        defcomponent CompMemoRebuild do
          def render(assigns) do
            {_sel, set_sel} = use_state(:all)

            ~F"""
            <ul>
              {for {val, label} <- assigns.items do}
                <li><a on_click={fn -> set_sel.(val) end}>{label}</a></li>
              {end}
            </ul>
            """
          end
        end
      end

      items1 = [{:all, "All"}, {:active, "Active"}]
      items2 = [{:all, "All"}, {:done, "Done"}, {:extra, "Extra"}]

      {tree1, _, _} =
        Reconciler.mount(CompMemoRebuildComp.CompMemoRebuild, %{items: items1}, owner_pid: self())

      h1 = FiberTree.get_event_handler(tree1, "root", 0)
      assert is_function(h1)

      # Re-render with different items — deps changed, handlers recomputed
      {tree2, _, _} =
        Reconciler.update(tree1, "root", %{items: items2}, owner_pid: self())

      h2 = FiberTree.get_event_handler(tree2, "root", 0)
      assert is_function(h2)

      # Different items list → new handlers
      assert FiberTree.get_event_handler(tree2, "root", 2) != nil,
             "third handler exists after items expanded"
    end
  end
end
