defmodule Filament.Core.DispatchEventTest do
  @moduledoc """
  Phase 3.2: `Filament.Core.dispatch_event/4` walks fiber ancestry on event
  dispatch — capture phase root-to-target's-parent (each ancestor's capture
  handlers fire), then the target's event handler at the given slot.
  `Filament.Core.stop_propagation/1` halts the walk after the current
  handler.

  Backends contribute event sources (DOM events for web, terminal escape
  sequences for TUI); the walker is target-agnostic.
  """
  use ExUnit.Case, async: true

  alias Filament.Core
  alias Filament.Fiber

  defp fiber(opts) do
    Fiber.new(opts)
  end

  defp tree(fibers) do
    Map.new(fibers, &{&1.id, &1})
  end

  describe "dispatch_event/4 — single fiber" do
    test "fires the target's event handler at the given slot" do
      handler = fn params -> send(self(), {:fired, params}) end

      tree =
        tree([
          fiber(id: "root", component: __MODULE__, event_handlers: %{0 => handler})
        ])

      assert {:ok, _} = Core.dispatch_event(tree, "root", 0, %{key: :enter})

      assert_received {:fired, %{key: :enter}}
    end

    test "missing target returns {:error, :no_target}" do
      assert {:error, :no_target} = Core.dispatch_event(tree([]), "ghost", 0)
    end

    test "missing handler at slot is a no-op (no error)" do
      tree =
        tree([
          fiber(id: "root", component: __MODULE__, event_handlers: %{})
        ])

      assert {:ok, _} = Core.dispatch_event(tree, "root", 0)
    end
  end

  describe "dispatch_event/4 — capture phase" do
    test "ancestor capture handlers fire root-to-target before target's handler" do
      capture_root = fn _ -> send(self(), {:capture, :root}) end
      capture_mid = fn _ -> send(self(), {:capture, :mid}) end
      target_handler = fn _ -> send(self(), {:target}) end

      tree =
        tree([
          fiber(id: "root", component: __MODULE__, capture_handlers: %{0 => capture_root}),
          fiber(
            id: "root.mid",
            component: __MODULE__,
            parent_id: "root",
            capture_handlers: %{0 => capture_mid}
          ),
          fiber(
            id: "root.mid.leaf",
            component: __MODULE__,
            parent_id: "root.mid",
            event_handlers: %{0 => target_handler}
          )
        ])

      assert {:ok, _} = Core.dispatch_event(tree, "root.mid.leaf", 0)

      assert_received {:capture, :root}
      assert_received {:capture, :mid}
      assert_received {:target}
      refute_received _
    end

    test "fibers without capture handlers don't crash the walk" do
      target = fn _ -> send(self(), :target) end

      tree =
        tree([
          fiber(id: "root", component: __MODULE__),
          fiber(
            id: "root.leaf",
            component: __MODULE__,
            parent_id: "root",
            event_handlers: %{0 => target}
          )
        ])

      assert {:ok, _} = Core.dispatch_event(tree, "root.leaf", 0)
      assert_received :target
    end

    test "only the ancestors above the target run their capture handlers" do
      sibling_capture = fn _ -> send(self(), {:capture, :sibling}) end
      target_handler = fn _ -> send(self(), :target) end

      tree =
        tree([
          fiber(id: "root", component: __MODULE__),
          fiber(
            id: "root.sibling",
            component: __MODULE__,
            parent_id: "root",
            capture_handlers: %{0 => sibling_capture}
          ),
          fiber(
            id: "root.target",
            component: __MODULE__,
            parent_id: "root",
            event_handlers: %{0 => target_handler}
          )
        ])

      assert {:ok, _} = Core.dispatch_event(tree, "root.target", 0)

      assert_received :target
      refute_received {:capture, :sibling}
    end
  end

  describe "stop_propagation/1" do
    test "a capture handler that calls stop_propagation halts the walk" do
      capture_root = fn _ ->
        send(self(), {:capture, :root})
        Core.stop_propagation(:trapped)
      end

      capture_mid = fn _ -> send(self(), {:capture, :mid}) end
      target = fn _ -> send(self(), :target) end

      tree =
        tree([
          fiber(id: "root", component: __MODULE__, capture_handlers: %{0 => capture_root}),
          fiber(
            id: "root.mid",
            component: __MODULE__,
            parent_id: "root",
            capture_handlers: %{0 => capture_mid}
          ),
          fiber(
            id: "root.mid.leaf",
            component: __MODULE__,
            parent_id: "root.mid",
            event_handlers: %{0 => target}
          )
        ])

      assert {:ok, {:stopped, :trapped}} = Core.dispatch_event(tree, "root.mid.leaf", 0)

      assert_received {:capture, :root}
      refute_received {:capture, :mid}
      refute_received :target
    end

    test "a target handler that calls stop_propagation returns the trapped value" do
      target = fn _ -> Core.stop_propagation(:done_early) end

      tree =
        tree([
          fiber(id: "root", component: __MODULE__, event_handlers: %{0 => target})
        ])

      assert {:ok, {:stopped, :done_early}} = Core.dispatch_event(tree, "root", 0)
    end
  end

  describe "dispatch_event/4 — handler arity" do
    test "0-arity handlers run with no args" do
      handler = fn -> send(self(), :ran) end

      tree =
        tree([
          fiber(id: "root", component: __MODULE__, event_handlers: %{0 => handler})
        ])

      assert {:ok, _} = Core.dispatch_event(tree, "root", 0)
      assert_received :ran
    end

    test "1-arity handlers receive params" do
      handler = fn params -> send(self(), {:ran, params}) end

      tree =
        tree([
          fiber(id: "root", component: __MODULE__, event_handlers: %{0 => handler})
        ])

      Core.dispatch_event(tree, "root", 0, %{key: "Esc"})
      assert_received {:ran, %{key: "Esc"}}
    end
  end
end
