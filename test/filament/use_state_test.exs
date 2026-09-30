defmodule Filament.UseStateTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.Hooks
  alias Filament.RenderContext

  describe "use_state/1" do
    test "first render returns {initial, setter}" do
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      {value, setter} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_state(:closed)
        end)

      assert value == :closed
      assert is_function(setter, 1)
    end

    test "second render returns previously committed value" do
      # First render commits the initial value as {value, setter} tuple
      fiber =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{0 => {:stored, fn _ -> :ok end}},
          status: :stable
        )

      {value, setter} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_state(:initial)
        end)

      assert value == :stored
      assert is_function(setter, 1)
    end

    test "setter raises when owner_pid is nil" do
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      {_value, setter} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_state(:initial)
        end)

      # Calling a setter without an owner is a programmer error — Reconciler.mount
      # was invoked without owner_pid: self(). Raise loudly rather than silently
      # dropping the update.
      assert_raise ArgumentError, ~r/use_state setter called but the render had no :owner_pid/, fn ->
        setter.(:new_value)
      end
    end

    test "two use_state calls get consecutive slot indices" do
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      {values, _ctx} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          {a, _setter_a} = Hooks.use_state(:a)
          {b, _setter_b} = Hooks.use_state(:b)
          {[a, b], Hooks.current_context()}
        end)

      assert values == [:a, :b]

      # Verify hook_index was incremented twice
      # (We check by seeing the second call read from slot 1, not slot 0)
      # If slot 1 was empty, b should be :b (the default)
      # Note: stored value is now {value, setter} tuple
      stable_setter = fn _ -> :ok end

      fiber2 =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{0 => {:stored_a, stable_setter}},
          status: :stable
        )

      {values2, _ctx2} =
        with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
          {a, _setter_a} = Hooks.use_state(:a)
          {b, _setter_b} = Hooks.use_state(:b)
          {[a, b], Hooks.current_context()}
        end)

      # First slot has stored value, second slot is empty (gets default)
      assert values2 == [:stored_a, :b]
    end

    test "setter built without an owner_pid raises when invoked" do
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      {_value, setter} =
        with_render_ctx("root", %{"root" => fiber}, nil, fn ->
          Hooks.use_state(:initial)
        end)

      # Building the setter is harmless; invoking it without an owner_pid is the
      # bug that this raise surfaces.
      assert is_function(setter, 1)

      assert_raise ArgumentError, fn ->
        setter.(:anything)
      end
    end
  end

  describe "use_state/1 with owner_pid" do
    test "setter sends message to owner_pid when set" do
      owner = self()
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      {_value, setter} =
        with_render_ctx("root", %{"root" => fiber}, owner, fn ->
          Hooks.use_state(:initial)
        end)

      assert :ok = setter.(:new_value)

      assert_receive {:filament_set_state, "root", 0, :new_value}, 100
    end

    test "setter uses correct slot index" do
      owner = self()
      fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      {_value1, setter1} =
        with_render_ctx("root", %{"root" => fiber}, owner, fn ->
          Hooks.use_state(:first)
        end)

      assert :ok = setter1.(:updated_first)
      assert_receive {:filament_set_state, "root", 0, :updated_first}, 100

      # Start fresh render for second slot
      {_, setter2} =
        with_render_ctx("root", %{"root" => fiber}, owner, fn ->
          _ = Hooks.use_state(:first)
          Hooks.use_state(:second)
        end)

      assert :ok = setter2.(:updated_second)
      assert_receive {:filament_set_state, "root", 1, :updated_second}, 100
    end

    test "setter is stable across renders" do
      owner = self()

      # First render: create a setter
      fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

      {_value1, setter1} =
        with_render_ctx("root", %{"root" => fiber1}, owner, fn ->
          Hooks.use_state(:initial)
        end)

      # Simulate a render pass: setter was committed, state was updated via setter
      # The slot now contains {new_value, setter1}
      new_state = :updated

      fiber2 =
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{0 => {new_state, setter1}},
          status: :stable
        )

      # Second render: should get the SAME setter function reference
      {_value2, setter2} =
        with_render_ctx("root", %{"root" => fiber2}, owner, fn ->
          Hooks.use_state(:initial)
        end)

      # The setter function reference must be identical
      assert setter1 === setter2
    end
  end

  # Test helper — inlined to avoid external dependencies
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
