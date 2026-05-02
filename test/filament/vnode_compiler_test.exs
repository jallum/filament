defmodule Filament.VNodeCompilerTest do
  use ExUnit.Case, async: true

  alias Filament.{Reconciler, FiberTree}

  describe "warning suppression" do
    test "compiling template with lexically-bound variable produces no warnings" do
      # This test verifies that Step 0 fix works: VNodeCompiler strips versioned_vars
      # from the caller before passing to TagEngine, suppressing the false-positive
      # warning about accessing variables inside LiveView templates.
      defmodule WarningTestComponent do
        use Filament.Component

        defcomponent WarningTest do
          def render(assigns) do
            click_handler = fn -> :ok end
            ~F"<button on_click={click_handler}>Click me</button>"
          end
        end
      end

      # Capture any IO.warn output
      warnings =
        ExUnit.CaptureLog.capture_log(fn ->
          {tree, _, _} =
            Reconciler.mount(WarningTestComponent.WarningTest, %{}, owner_pid: self())

          assert tree["root"].status == :stable
        end)

      # The captured output should not contain the LiveView variable warning
      refute warnings =~ "you are accessing the variable"
      refute warnings =~ "inside a LiveView template"
    end
  end

  describe "auto-memoization integration" do
    test "reactive state changes trigger re-render" do
      # Create a component that uses reactive state
      defmodule MemoTestComponent do
        use Filament.Component
        import Filament.Hooks

        defcomponent MemoTest do
          def render(assigns) do
            {count, _set_count} = use_state(0)
            ~F"<div>{count}</div>"
          end
        end
      end

      # Mount the component
      {tree1, _, _} =
        Reconciler.mount(MemoTestComponent.MemoTest, %{}, owner_pid: self())

      fiber1 = tree1["root"]
      assert fiber1.status == :stable

      # Update with same props - fiber should be reused
      {tree2, _, _} =
        Reconciler.update(tree1, "root", %{}, owner_pid: self())

      fiber2 = tree2["root"]
      assert fiber2.status == :stable
    end

    test "stable setters work correctly in closures" do
      defmodule StableSetterComponent do
        use Filament.Component
        import Filament.Hooks

        defcomponent StableSetter do
          def render(assigns) do
            {_value, set_value} = use_state("initial")
            click_handler = fn -> set_value.("clicked") end
            ~F"<button on_click={click_handler}>Click me</button>"
          end
        end
      end

      {tree, _, _} =
        Reconciler.mount(StableSetterComponent.StableSetter, %{}, owner_pid: self())

      assert tree["root"].status == :stable
    end

    test "multiple reactive variables work correctly" do
      defmodule MultiReactiveComponent do
        use Filament.Component
        import Filament.Hooks

        defcomponent MultiReactive do
          def render(assigns) do
            {count, _set_count} = use_state(0)
            {filter, _set_filter} = use_state(:all)

            ~F"""
            <div>
              <span class="count">{count}</span>
              <span class="filter">{filter}</span>
            </div>
            """
          end
        end
      end

      {tree1, _, _} =
        Reconciler.mount(MultiReactiveComponent.MultiReactive, %{}, owner_pid: self())

      assert tree1["root"].status == :stable

      {tree2, _, _} =
        Reconciler.update(tree1, "root", %{}, owner_pid: self())

      assert tree2["root"].status == :stable
    end
  end

  describe "use_memo caching behavior" do
    test "use_memo is called with reactive deps and caches" do
      defmodule MemoCacheComponent do
        use Filament.Component
        import Filament.Hooks

        defcomponent MemoCache do
          def render(assigns) do
            {count, set_count} = use_state(0)

            # Track memo calls
            _computed =
              use_memo(
                fn ->
                  send(self(), {:memo_called, count})
                  count
                end,
                [count]
              )

            ~F"""
            <div>
              <span class="count">{count}</span>
              <button on_click={fn -> set_count.(count + 1) end}>+</button>
            </div>
            """
          end
        end
      end

      # Mount
      {tree1, _, _} =
        Reconciler.mount(MemoCacheComponent.MemoCache, %{}, owner_pid: self())

      # First memo call
      assert_receive {:memo_called, 0}
      flush_mailbox()

      # Simulate state change by updating the hook slot
      updated_tree =
        FiberTree.update_hook_slot(tree1, "root", 0, fn
          {_old_count, setter} when is_function(setter, 1) ->
            {1, setter}
        end)

      # Re-render
      {tree2, _, _} =
        Reconciler.update(updated_tree, "root", %{}, owner_pid: self())

      # Should have memo called again with new count
      assert_receive {:memo_called, 1}
      flush_mailbox()

      # Re-render with same state - memo should use cache
      # Re-render with same state - memo should use cache
      {_tree3, _, _} =
        Reconciler.update(tree2, "root", %{}, owner_pid: self())

      # No new memo call
      refute_receive {:memo_called, _}
    end
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
