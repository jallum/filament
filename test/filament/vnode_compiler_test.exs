defmodule Filament.VNodeCompilerTest do
  use ExUnit.Case, async: true

  alias Filament.{Reconciler, FiberTree}

  describe "assigns-free render" do
    test "render without assigns in scope compiles and renders correctly" do
      defmodule AssignsFreeComp do
        use Filament.Component
        import Filament.Hooks

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
        Reconciler.mount(AssignsFreeComp.AssignsFree, %{text: "hello", count: 3},
          owner_pid: self()
        )

      html = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
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

  describe "stable closure fn identity" do
    # Closure capturing only a stable setter (not in reactive_vars because it is
    # never referenced via @) → use_memo(fn -> closure end, []) → same fn object
    # every render.
    test "stable closure produces identical fn reference across renders" do
      defmodule StableClosureComp do
        use Filament.Component
        import Filament.Hooks

        defcomponent StableClosure do
          def render(assigns) do
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
    # Closure capturing a reactive var (@count in the template) → deps = [count].
    # When count changes, use_memo invalidates and produces a new fn.
    test "reactive closure produces new fn reference when dep changes" do
      defmodule ReactiveClosureComp do
        use Filament.Component
        import Filament.Hooks

        defcomponent ReactiveClosure do
          def render(assigns) do
            {count, set_count} = use_state(0)
            ~F'<button on_click={fn -> set_count.(@count + 1) end}>+</button>'
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
        use Filament.Component
        import Filament.Hooks

        defcomponent ReactiveClosureStable do
          def render(assigns) do
            {count, set_count} = use_state(0)
            ~F'<button on_click={fn -> set_count.(@count + 1) end}>+</button>'
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
end
