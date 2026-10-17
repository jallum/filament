defmodule Filament.Hooks.Slots do
  @moduledoc false
  # The hook-slot primitives the hooks in `Filament.Hooks` are built from.

  alias Filament.RenderContext

  @spec use_slot(default :: term()) ::
          {slot_index :: non_neg_integer(), previous_value :: term(), context :: RenderContext.t()}
  def use_slot(default) do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError,
              "hook called outside a render pass — hooks may only be called from render/1"

    index = ctx.hook_index

    # Look up previous value: first from ctx.hook_slots (for new child fibers),
    # then from fiber_tree for existing fibers being re-rendered
    previous =
      case Map.get(ctx.hook_slots, index) do
        nil ->
          fiber = Map.get(ctx.fiber_tree, ctx.fiber_id)
          if fiber, do: Map.get(fiber.hook_slots, index, default), else: default

        value ->
          value
      end

    Process.put(:filament_render_context, %{ctx | hook_index: index + 1})
    {index, previous, ctx}
  end

  @spec commit_slot(slot_index :: non_neg_integer(), value :: term()) :: :ok
  def commit_slot(index, value) do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError, "commit_slot called outside a render pass"

    updated = Map.put(ctx.new_hook_slots, index, value)
    Process.put(:filament_render_context, %{ctx | new_hook_slots: updated})
    :ok
  end

  @spec current_context() :: RenderContext.t() | nil
  def current_context, do: Process.get(:filament_render_context)
end
