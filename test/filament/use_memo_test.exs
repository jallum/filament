defmodule Filament.UseMemoTest do
  use ExUnit.Case, async: true

  alias Filament.{Hooks, Fiber, RenderContext}

  describe "use_memo/2" do
    test "first render — fun.() is called, result returned" do
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      result =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_memo(fn -> :computed end, [:dep])
        end)

      assert result == :computed
    end

    test "second render, same deps — fun.() is NOT called" do
      counter = start_counter()

      # First render
      fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      _result1 =
        with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, [:a, :b])
        end)

      count_after_first = get_count(counter)
      assert count_after_first == 1

      # Second render with same deps — read cached value from hook_slots
      fiber2 =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{0 => {[:a, :b], :cached}},
          status: :stable
        )

      result2 =
        with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, [:a, :b])
        end)

      assert result2 == :cached
      assert get_count(counter) == 1, "fun.() should not have been called again"
    end

    test "second render, different deps — fun.() IS called" do
      counter = start_counter()

      # First render
      fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      _result1 =
        with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, [:a, :b])
        end)

      assert get_count(counter) == 1

      # Second render with different deps
      fiber2 =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{0 => {[:a, :b], :cached}},
          status: :stable
        )

      _result2 =
        with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, [:changed])
        end)

      assert get_count(counter) == 2, "fun.() should have been called again"
    end

    test "deps == [] — fun.() called only on first render" do
      counter = start_counter()

      # First render
      fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      _r1 =
        with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, [])
        end)

      assert get_count(counter) == 1

      # Second render, same empty deps
      fiber2 =
        Fiber.new(id: "root", component: nil, hook_slots: %{0 => {[], :cached}}, status: :stable)

      _r2 =
        with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, [])
        end)

      assert get_count(counter) == 1

      # Third render, same empty deps
      fiber3 =
        Fiber.new(id: "root", component: nil, hook_slots: %{0 => {[], :cached}}, status: :stable)

      _r3 =
        with_render_ctx("root", %{"root" => fiber3}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, [])
        end)

      assert get_count(counter) == 1, "fun.() should only have been called once"
    end

    test "deps == :no_deps — fun.() called on every render" do
      counter = start_counter()

      # First render
      fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      _r1 =
        with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, :no_deps)
        end)

      assert get_count(counter) == 1

      # Second render
      fiber2 =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{0 => {:no_deps, :cached1}},
          status: :stable
        )

      _r2 =
        with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, :no_deps)
        end)

      assert get_count(counter) == 2

      # Third render
      fiber3 =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{0 => {:no_deps, :cached2}},
          status: :stable
        )

      _r3 =
        with_render_ctx("root", %{"root" => fiber3}, nil, fn ->
          Hooks.use_memo(fn -> increment(counter) end, :no_deps)
        end)

      assert get_count(counter) == 3, "fun.() should have been called on every render"
    end

    test "use_memo and use_state in same render — slot indices don't collide" do
      # First render — no stored slots
      fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      {state, _setter, memo} =
        with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
          {s, setter} = Hooks.use_state(:x)
          m = Hooks.use_memo(fn -> :y end, [])
          {s, setter, m}
        end)

      assert state == :x
      assert memo == :y

      # Second render — verify correct slot values
      fiber2 =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{0 => :x, 1 => {{}, :y}},
          status: :stable
        )

      {state2, _setter2, memo2} =
        with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
          {s2, setter2} = Hooks.use_state(:x)
          m2 = Hooks.use_memo(fn -> :y end, [])
          {s2, setter2, m2}
        end)

      assert state2 == :x
      assert memo2 == :y
    end

    test "fun.() raises — exception propagates unmodified" do
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      assert_raise RuntimeError, "boom", fn ->
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_memo(fn -> raise "boom" end, [])
        end)
      end
    end
  end

  # Simple counter using Agent
  defp start_counter do
    {:ok, pid} = Agent.start(fn -> 0 end)
    pid
  end

  defp increment(pid) do
    Agent.update(pid, &(&1 + 1))
    :ok
  end

  defp get_count(pid) do
    Agent.get(pid, & &1)
  end

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
