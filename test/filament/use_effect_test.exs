defmodule Filament.UseEffectTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.Hooks
  alias Filament.LiveView
  alias Filament.Reconciler
  alias Filament.RenderContext

  # --- Rung-1: unit tests (simulated render, no LiveView) ---

  test "1. effect runs on first render (deps = [])" do
    tracker = start_tracker()
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    pending_effects =
      with_render_ctx("root", %{"root" => fiber}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :effect)
            fn -> append(tracker, :cleanup) end
          end,
          []
        )

        Hooks.current_context().pending_effects
      end)

    assert length(pending_effects) == 1
    assert calls(tracker) == []

    {new_tree, ran} = LiveView.apply_effects(pending_effects, %{"root" => fiber})
    assert ran == 1
    assert calls(tracker) == [:effect]

    # Cleanup stored for future use
    {deps, stored_cleanup} = new_tree["root"].hook_slots[0]
    assert deps == []
    assert is_function(stored_cleanup, 0)
  end

  test "2. effect does NOT re-run when deps unchanged" do
    tracker = start_tracker()

    # First render
    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    effects1 =
      with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :effect)
            nil
          end,
          []
        )

        Hooks.current_context().pending_effects
      end)

    {tree1, _ran} = LiveView.apply_effects(effects1, %{"root" => fiber1})
    assert calls(tracker) == [:effect]

    # Second render — same deps, effect should NOT be queued
    fiber2 = %{tree1["root"] | hook_slots: %{0 => {[], nil}}}

    effects2 =
      with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :effect)
            nil
          end,
          []
        )

        Hooks.current_context().pending_effects
      end)

    assert effects2 == []
    assert length(calls(tracker)) == 1
  end

  test "3. effect re-runs when deps change" do
    tracker = start_tracker()

    # First render
    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    effects1 =
      with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :effect)
            nil
          end,
          [false]
        )

        Hooks.current_context().pending_effects
      end)

    {tree1, _} = LiveView.apply_effects(effects1, %{"root" => fiber1})
    assert length(calls(tracker)) == 1

    # Second render with changed deps
    fiber2 = %{tree1["root"] | hook_slots: %{0 => {[false], nil}}}

    effects2 =
      with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :effect)
            nil
          end,
          [true]
        )

        Hooks.current_context().pending_effects
      end)

    assert length(effects2) == 1
    LiveView.apply_effects(effects2, %{"root" => fiber2})
    assert length(calls(tracker)) == 2
  end

  test "4. cleanup runs before effect re-fires" do
    tracker = start_tracker()

    # First render — store a real cleanup function
    cleanup_fn = fn -> append(tracker, :cleanup) end

    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    effects1 =
      with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :effect)
            cleanup_fn
          end,
          [[:a]]
        )

        Hooks.current_context().pending_effects
      end)

    {tree1, _} = LiveView.apply_effects(effects1, %{"root" => fiber1})
    assert calls(tracker) == [:effect]

    # Second render with changed deps — cleanup should fire before new effect
    # The cleanup_fn is stored in hook_slots after first apply_effects
    fiber2 = %{tree1["root"] | hook_slots: %{0 => {[:a], cleanup_fn}}}

    effects2 =
      with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :effect)
            fn -> append(tracker, :cleanup) end
          end,
          [[:b]]
        )

        Hooks.current_context().pending_effects
      end)

    LiveView.apply_effects(effects2, %{"root" => fiber2})

    calls = calls(tracker)
    assert length(calls) == 3
    # cleanup from first run fires before second effect
    assert Enum.at(calls, 1) == :cleanup
    assert Enum.at(calls, 2) == :effect
  end

  test "5. cleanup runs on unmount" do
    tracker = start_tracker()

    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    effects =
      with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :effect)
            fn -> append(tracker, :cleanup) end
          end,
          []
        )

        Hooks.current_context().pending_effects
      end)

    {tree, _} = LiveView.apply_effects(effects, %{"root" => fiber1})

    # Unmount
    Reconciler.unmount(tree)

    calls = calls(tracker)
    assert :effect in calls
    assert :cleanup in calls
  end

  test "6. deps == :always causes effect to run on every render" do
    tracker = start_tracker()

    # First render
    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    effects1 =
      with_render_ctx("root", %{"root" => fiber1}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :ran)
            nil
          end,
          :always
        )

        Hooks.current_context().pending_effects
      end)

    {tree1, _} = LiveView.apply_effects(effects1, %{"root" => fiber1})
    assert length(calls(tracker)) == 1

    # Second render — :always re-runs
    fiber2 = %{tree1["root"] | hook_slots: %{0 => {:always, nil}}}

    effects2 =
      with_render_ctx("root", %{"root" => fiber2}, nil, fn ->
        Hooks.use_effect(
          fn ->
            append(tracker, :ran)
            nil
          end,
          :always
        )

        Hooks.current_context().pending_effects
      end)

    assert length(effects2) == 1
    LiveView.apply_effects(effects2, %{"root" => fiber2})
    assert length(calls(tracker)) == 2
  end

  test "7. effect fn returns nil — no crash, no cleanup stored" do
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    effects =
      with_render_ctx("root", %{"root" => fiber}, nil, fn ->
        Hooks.use_effect(fn -> nil end, [])
        Hooks.current_context().pending_effects
      end)

    {tree, _} = LiveView.apply_effects(effects, %{"root" => fiber})
    assert tree["root"].hook_slots[0] == {[], nil}
    assert :ok = Reconciler.unmount(tree)
  end

  test "8. stale fiber — apply_effects skips gracefully" do
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    effects =
      with_render_ctx("root", %{"root" => fiber}, nil, fn ->
        Hooks.use_effect(fn -> raise "should not run" end, [])
        Hooks.current_context().pending_effects
      end)

    # Tree doesn't contain "root" — simulating unmounted fiber
    empty_tree = %{"other" => fiber}

    {result_tree, ran} = LiveView.apply_effects(effects, empty_tree)
    assert ran == 0
    assert Map.has_key?(result_tree, "other")
  end

  # --- Helpers ---

  defp start_tracker do
    {:ok, pid} = Agent.start(fn -> [] end)
    pid
  end

  defp append(tracker, tag) do
    Agent.update(tracker, fn acc -> acc ++ [tag] end)
  end

  defp calls(tracker) do
    Agent.get(tracker, & &1)
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
