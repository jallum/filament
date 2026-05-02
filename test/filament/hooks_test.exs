defmodule Filament.HooksTest do
  use ExUnit.Case, async: true

  alias Filament.{Hooks, Fiber, RenderContext}

  describe "use_slot/1" do
    test "raises ArgumentError when called outside render pass" do
      assert_raise ArgumentError,
                   "hook called outside a render pass — hooks may only be called from render/1",
                   fn ->
                     Hooks.use_slot(:default)
                   end
    end

    test "returns (0, default, ctx) on first call during render" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)

      {index, value, ctx} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_slot(:default)
        end)

      assert index == 0
      assert value == :default
      assert %RenderContext{} = ctx
    end

    test "returns incrementing indices on repeated calls" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)

      {index0, _value, _ctx} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_slot(:first)
        end)

      assert index0 == 0

      {index1, _value, _ctx} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_slot(:first)
          Hooks.use_slot(:second)
        end)

      # Each render pass starts fresh, so second call returns index 1
      assert index1 == 1
    end

    test "returns previously committed value from fiber" do
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{0 => :stored}, status: :stable)

      {_index, value, _ctx} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_slot(:default)
        end)

      assert value == :stored
    end

    test "committed value from render pass is not visible until next render" do
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      # First render: commit a value
      new_slots =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          {index, value, _ctx} = Hooks.use_slot(:default)
          assert index == 0
          assert value == :default
          Hooks.commit_slot(index, :committed)

          # Read back the new_hook_slots from context
          ctx = Hooks.current_context()
          ctx.new_hook_slots
        end)

      assert new_slots == %{0 => :committed}

      # Simulate next render with the committed slot value
      fiber_after = Fiber.new(id: "root", component: nil, hook_slots: new_slots, status: :stable)

      {_index, value, _ctx} =
        with_render_ctx("root", %{"root" => fiber_after}, nil, fn ->
          Hooks.use_slot(:default)
        end)

      assert value == :committed
    end
  end

  describe "commit_slot/2" do
    test "raises ArgumentError when called outside render pass" do
      assert_raise ArgumentError, "commit_slot called outside a render pass", fn ->
        Hooks.commit_slot(0, :value)
      end
    end

    test "accumulates values in render context" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)

      new_slots =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.commit_slot(0, :alpha)
          Hooks.commit_slot(1, :beta)

          ctx = Hooks.current_context()
          ctx.new_hook_slots
        end)

      assert new_slots == %{0 => :alpha, 1 => :beta}
    end
  end

  describe "current_context/0" do
    test "returns nil when called outside render pass" do
      assert Hooks.current_context() == nil
    end

    test "returns the current context struct when inside render" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)

      ctx =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.current_context()
        end)

      assert %RenderContext{} = ctx
      assert ctx.fiber_id == "root"
    end
  end

  describe "memo_at/3" do
    test "raises when called outside render pass" do
      assert_raise ArgumentError,
                   "hook called outside a render pass — hooks may only be called from render/1",
                   fn -> Hooks.memo_at({:t, 0}, [], fn -> :value end) end
    end

    test "calls factory on first render and stores result" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)

      {value, new_slots} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          val = Hooks.memo_at({:t, 0}, [], fn -> :computed end)
          {val, Hooks.current_context().new_hook_slots}
        end)

      assert value == :computed
      assert new_slots[{:t, 0}] == {[], :computed}
    end

    test "reuses cached value when deps unchanged" do
      calls = :counters.new(1, [])

      factory = fn ->
        :counters.add(calls, 1, 1)
        :result
      end

      fiber =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{{:t, 0} => {[:dep], :cached}},
          status: :stable
        )

      value =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.memo_at({:t, 0}, [:dep], factory)
        end)

      assert value == :cached
      assert :counters.get(calls, 1) == 0
    end

    test "recomputes when deps change" do
      fiber =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{{:t, 0} => {[:old], :stale}},
          status: :stable
        )

      value =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.memo_at({:t, 0}, [:new], fn -> :fresh end)
        end)

      assert value == :fresh
    end

    test "plain integer key works alongside {:t, N} tuple key" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)

      {v1, v2, new_slots} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          a = Hooks.memo_at(0, [], fn -> :plain end)
          b = Hooks.memo_at({:t, 0}, [], fn -> :tagged end)
          {a, b, Hooks.current_context().new_hook_slots}
        end)

      assert v1 == :plain
      assert v2 == :tagged
      assert new_slots[0] == {[], :plain}
      assert new_slots[{:t, 0}] == {[], :tagged}
    end

    test "does not increment hook_index" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)

      hook_index_after =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.memo_at({:t, 0}, [], fn -> :x end)
          Hooks.memo_at({:t, 1}, [], fn -> :y end)
          Hooks.current_context().hook_index
        end)

      assert hook_index_after == 0
    end
  end

  describe "event_at/2" do
    test "raises when called outside render pass" do
      assert_raise ArgumentError,
                   "hook called outside a render pass — hooks may only be called from render/1",
                   fn -> Hooks.event_at(0, fn -> :action end) end
    end

    test "stores handler and returns wire ref" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)
      handler = fn -> :action end

      {wire_ref, new_handlers} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          ref = Hooks.event_at(0, handler)
          {ref, Hooks.current_context().new_event_handlers}
        end)

      assert wire_ref == "root:0"
      assert new_handlers[0] === handler
    end

    test "two handlers at distinct explicit slots" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)
      h0 = fn -> :a end
      h1 = fn -> :b end

      {ref0, ref1, handlers} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          r0 = Hooks.event_at(0, h0)
          r1 = Hooks.event_at(1, h1)
          {r0, r1, Hooks.current_context().new_event_handlers}
        end)

      assert ref0 == "root:0"
      assert ref1 == "root:1"
      assert handlers[0] === h0
      assert handlers[1] === h1
    end

    test "does not increment event_handler_index" do
      fiber = Fiber.new(id: "root", component: nil, status: :stable)

      idx_after =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.event_at(0, fn -> :x end)
          Hooks.event_at(5, fn -> :y end)
          Hooks.current_context().event_handler_index
        end)

      assert idx_after == 0
    end
  end

  # Test helper
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
end
