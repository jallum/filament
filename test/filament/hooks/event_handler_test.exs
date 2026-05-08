defmodule Filament.Hooks.EventHandlerTest do
  use ExUnit.Case

  alias Filament.Fiber
  alias Filament.FiberTree
  alias Filament.Hooks
  alias Filament.RenderContext
  alias Phoenix.LiveView.Lifecycle

  defmodule TestLiveView do
    use Filament.LiveView

    def root_component, do: nil
  end

  # --- Tests ---

  test "1. register_event_handler returns stable ref" do
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    {ref0, ref1} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        r0 = Hooks.register_event_handler(fn -> :ok end)
        r1 = Hooks.register_event_handler(fn -> :ok end)
        {r0, r1}
      end)

    assert ref0 == "root:0"
    assert ref1 == "root:1"
  end

  test "2. register_event_handler accumulates in context" do
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    handlers =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.register_event_handler(fn -> :a end)
        Hooks.register_event_handler(fn -> :b end)
        Hooks.current_context().new_event_handlers
      end)

    assert map_size(handlers) == 2
    assert handlers[0].() == :a
    assert handlers[1].() == :b
  end

  test "3. 0-arity handler dispatched via handle_event" do
    test_pid = self()

    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{},
        event_handlers: %{0 => fn -> send(test_pid, :clicked) end},
        status: :stable
      )

    tree = %{"root" => fiber}
    socket = fake_socket(tree)

    assert {:noreply, _socket} =
             TestLiveView.handle_event("filament:root:0", %{}, socket)

    assert_receive :clicked
  end

  test "4. 1-arity handler receives params" do
    test_pid = self()

    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{},
        event_handlers: %{0 => fn params -> send(test_pid, {:params, params}) end},
        status: :stable
      )

    tree = %{"root" => fiber}
    socket = fake_socket(tree)

    assert {:noreply, _socket} =
             TestLiveView.handle_event(
               "filament:root:0",
               %{"value" => "hello"},
               socket
             )

    assert_receive {:params, %{"value" => "hello"}}
  end

  test "5. stale ref ignored" do
    socket = fake_socket(%{})

    assert {:noreply, ^socket} =
             TestLiveView.handle_event(
               "filament:missing:0",
               %{},
               socket
             )
  end

  test "6. reconciler applies new_event_handlers after render" do
    # Simulate a render pass that registers handlers
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    ctx = %RenderContext{
      fiber_id: "root",
      fiber_tree: %{"root" => fiber},
      owner_pid: self()
    }

    Process.put(:filament_render_context, ctx)

    Hooks.register_event_handler(fn -> :click end)
    Hooks.register_event_handler(fn -> :submit end)

    final_ctx = Hooks.current_context()
    Process.delete(:filament_render_context)

    # Apply the new_event_handlers to the fiber (as reconciler would)
    updated_fiber = %{fiber | event_handlers: final_ctx.new_event_handlers}

    assert map_size(updated_fiber.event_handlers) == 2
    assert updated_fiber.event_handlers[0].() == :click
    assert updated_fiber.event_handlers[1].() == :submit
  end

  test "7. FiberTree.get_event_handler lookups" do
    handler = fn -> :ok end

    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        event_handlers: %{0 => handler},
        status: :stable
      )

    tree = %{"root" => fiber}

    assert FiberTree.get_event_handler(tree, "root", 0) == handler
    assert FiberTree.get_event_handler(tree, "root", 1) == nil
    assert FiberTree.get_event_handler(tree, "missing", 0) == nil
  end

  test "use_event_ref/1 returns full filament wire ref with filament: prefix" do
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    {ref0, ref1} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        r0 = Filament.Experimental.Hooks.use_event_ref(fn -> :ok end)
        r1 = Filament.Experimental.Hooks.use_event_ref(fn -> :ok end)
        {r0, r1}
      end)

    assert ref0 == "filament:root:0"
    assert ref1 == "filament:root:1"
  end

  test "use_event_ref/1 handler is dispatched via handle_event" do
    test_pid = self()
    handler = fn %{"x" => v} -> send(test_pid, {:called, v}) end

    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    ref =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Filament.Experimental.Hooks.use_event_ref(handler)
      end)

    # Simulate what the reconciler does — store handler in the fiber
    ctx = %RenderContext{fiber_id: "root", fiber_tree: %{"root" => fiber}, owner_pid: self()}
    Process.put(:filament_render_context, ctx)
    Filament.Experimental.Hooks.use_event_ref(handler)
    new_handlers = Process.get(:filament_render_context).new_event_handlers
    Process.delete(:filament_render_context)

    fiber = %{fiber | event_handlers: new_handlers}
    tree = %{"root" => fiber}
    socket = fake_socket(tree)

    # Strip "filament:" prefix, as handle_event does, then dispatch
    "filament:" <> wire_ref = ref
    assert {:noreply, _} = Filament.LiveView.dispatch_filament_event(wire_ref, %{"x" => 42}, socket)
    assert_receive {:called, 42}
  end

  # --- Helpers ---

  defp with_render_ctx(fiber_id, fiber_tree, owner_pid, fun) do
    ctx = %RenderContext{
      fiber_id: fiber_id,
      fiber_tree: fiber_tree,
      owner_pid: owner_pid
    }

    Process.put(:filament_render_context, ctx)

    try do
      fun.()
    after
      Process.delete(:filament_render_context)
    end
  end

  defp fake_socket(tree) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        _filament_tree: tree,
        _filament_rendered: %Phoenix.LiveView.Rendered{},
        __changed__: %{}
      },
      private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
    }
  end
end
