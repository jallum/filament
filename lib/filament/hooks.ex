defmodule Filament.Hooks do
  @moduledoc """
  Low-level hook slot primitives. Not called by application code directly.
  Application code uses use_state/1, use_memo/2, use_effect/2.

  Rules of hooks:
  1. Only call hooks at the top level of render/1.
  2. Only call hooks during a render pass.
  3. Hooks are identified by call order (slot index). Conditional hooks corrupt state.
  """

  alias Filament.RenderContext

  @doc """
  Acquires the next hook slot. Returns {slot_index, previous_value, context} where:
  - slot_index is the current index (0-based, increments with each call)
  - previous_value is the value stored in this slot from the PREVIOUS render
    (or the given default if this is the first render or the slot is empty)
  - context is the current RenderContext (for use by the calling hook)

  Raises if called outside a render pass (no context in process dictionary).
  """
  @spec use_slot(default :: term()) ::
          {slot_index :: non_neg_integer(), previous_value :: term(),
           context :: RenderContext.t()}
  def use_slot(default) do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError,
              "hook called outside a render pass — hooks may only be called from render/1"

    index = ctx.hook_index
    fiber = Map.get(ctx.fiber_tree, ctx.fiber_id)
    previous = if fiber, do: Map.get(fiber.hook_slots, index, default), else: default

    Process.put(:filament_render_context, %{ctx | hook_index: index + 1})
    {index, previous, ctx}
  end

  @doc """
  Writes a new value for the given slot index into the render context accumulator.
  The value is committed to the fiber after the render pass completes.
  """
  @spec commit_slot(slot_index :: non_neg_integer(), value :: term()) :: :ok
  def commit_slot(index, value) do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError, "commit_slot called outside a render pass"

    updated = Map.put(ctx.new_hook_slots, index, value)
    Process.put(:filament_render_context, %{ctx | new_hook_slots: updated})
    :ok
  end

  @doc """
  Returns the current render context, or nil if called outside a render pass.
  Used by hooks that need owner_pid (C2) or to schedule effects (C4).
  """
  @spec current_context() :: RenderContext.t() | nil
  def current_context, do: Process.get(:filament_render_context)

  @doc """
  Returns the current state value and a setter function.

  On the first render of this fiber, returns {initial, setter}.
  On subsequent renders, returns the most recently set value (or initial if never changed).

  The setter is a closure. Call it from event handlers or effects to trigger a re-render.
  Calling the setter sends a message to the owning LiveView process, which re-renders
  the affected fiber.

  Rules: call only at the top level of render/1. Do not call inside conditionals.
  """
  @spec use_state(initial :: term()) :: {value :: term(), setter :: (term() -> :ok)}
  def use_state(initial) do
    {index, previous, ctx} = use_slot(initial)
    setter = build_setter(ctx.fiber_id, index, ctx.owner_pid)
    commit_slot(index, previous)
    {previous, setter}
  end

  defp build_setter(fiber_id, slot_index, owner_pid) when is_pid(owner_pid) do
    fn new_value ->
      send(owner_pid, {:filament_set_state, fiber_id, slot_index, new_value})
      :ok
    end
  end

  defp build_setter(_fiber_id, _slot_index, nil) do
    fn _new_value -> :ok end
  end
end
