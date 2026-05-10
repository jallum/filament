defmodule Filament.EventPhaseTest do
  @moduledoc """
  Phase 3.1: phase-aware event handler registration. `event_at/2` and
  `register_event_handler/1` continue to register bubble handlers (the
  default) for backward compatibility; new `/3` and `/2` arities accept an
  explicit phase tag.

  Capture and bubble handlers at the same slot index live in separate
  per-fiber maps and are looked up independently. Phase 3.2 introduces the
  walker that fires them in capture/target/bubble order.
  """
  use ExUnit.Case, async: true

  alias Filament.FiberTree
  alias Filament.Hooks
  alias Filament.RenderContext

  setup do
    ctx = %RenderContext{
      fiber_id: "root",
      fiber_tree: %{},
      new_event_handlers: %{},
      new_capture_handlers: %{},
      event_handler_index: 0,
      hook_index: 0,
      new_hook_slots: %{}
    }

    Process.put(:filament_render_context, ctx)
    on_exit(fn -> Process.delete(:filament_render_context) end)
    :ok
  end

  describe "event_at/3 with explicit phase" do
    test "default phase is :bubble (back-compat with event_at/2)" do
      Hooks.event_at(0, fn -> :clicked end)

      ctx = Process.get(:filament_render_context)
      assert is_function(Map.get(ctx.new_event_handlers, 0))
      assert ctx.new_capture_handlers == %{}
    end

    test ":capture phase stores in a separate map" do
      Hooks.event_at(0, fn -> :captured end, :capture)

      ctx = Process.get(:filament_render_context)
      assert ctx.new_event_handlers == %{}
      assert is_function(Map.get(ctx.new_capture_handlers, 0))
    end

    test "capture and bubble at the same slot are distinct" do
      Hooks.event_at(0, fn -> :bubble_at_0 end)
      Hooks.event_at(0, fn -> :capture_at_0 end, :capture)

      ctx = Process.get(:filament_render_context)
      assert Map.get(ctx.new_event_handlers, 0).() == :bubble_at_0
      assert Map.get(ctx.new_capture_handlers, 0).() == :capture_at_0
    end
  end

  describe "register_event_handler/2 with explicit phase" do
    test "default phase is :bubble" do
      _ref = Hooks.register_event_handler(fn -> :ok end)

      ctx = Process.get(:filament_render_context)
      assert is_function(Map.get(ctx.new_event_handlers, 0))
      assert ctx.event_handler_index == 1
    end

    test ":capture phase uses an independent slot space" do
      Hooks.register_event_handler(fn -> :bubble_0 end)
      Hooks.register_event_handler(fn -> :bubble_1 end)
      Hooks.register_event_handler(fn -> :capture_0 end, :capture)

      ctx = Process.get(:filament_render_context)
      # Bubble counter advanced twice
      assert ctx.event_handler_index == 2
      assert map_size(ctx.new_event_handlers) == 2
      # Capture got its own slot 0
      assert Map.has_key?(ctx.new_capture_handlers, 0)
    end
  end

  describe "FiberTree.get_event_handler/3 and /4" do
    setup do
      bubble = fn -> :bubble end
      capture = fn -> :capture end

      fiber = %Filament.Fiber{
        id: "root",
        component: __MODULE__,
        event_handlers: %{0 => bubble},
        capture_handlers: %{0 => capture}
      }

      {:ok, tree: %{"root" => fiber}, bubble: bubble, capture: capture}
    end

    test "/3 defaults to bubble (backward compatible)", %{tree: tree, bubble: bubble} do
      assert FiberTree.get_event_handler(tree, "root", 0) === bubble
    end

    test "/4 with :bubble explicitly", %{tree: tree, bubble: bubble} do
      assert FiberTree.get_event_handler(tree, "root", 0, :bubble) === bubble
    end

    test "/4 with :capture", %{tree: tree, capture: capture} do
      assert FiberTree.get_event_handler(tree, "root", 0, :capture) === capture
    end

    test "missing fiber returns nil", %{tree: tree} do
      assert FiberTree.get_event_handler(tree, "ghost", 0) == nil
      assert FiberTree.get_event_handler(tree, "ghost", 0, :capture) == nil
    end

    test "missing handler at slot returns nil", %{tree: tree} do
      assert FiberTree.get_event_handler(tree, "root", 999) == nil
      assert FiberTree.get_event_handler(tree, "root", 999, :capture) == nil
    end
  end
end
