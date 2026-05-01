defmodule Filament.FiberTree do
  @moduledoc """
  Helper functions for operating on the fiber tree map.

  The fiber tree is a `%{String.t() => Filament.Fiber.t()}` map keyed by fiber ID.
  """

  @type t :: %{String.t() => Filament.Fiber.t()}

  @doc """
  Look up the event handler at `handler_index` for the fiber with `fiber_id`.
  Returns the handler function or nil if not found.
  """
  @spec get_event_handler(t(), String.t(), non_neg_integer()) :: function() | nil
  def get_event_handler(tree, fiber_id, handler_index) do
    case Map.get(tree, fiber_id) do
      nil -> nil
      fiber -> Map.get(fiber.event_handlers, handler_index)
    end
  end

  @doc """
  Apply `updater` to hook slot `slot_index` of the fiber with `fiber_id`.
  Returns the updated tree. No-ops if fiber_id not found.
  """
  @spec update_hook_slot(
          t(),
          String.t(),
          non_neg_integer(),
          (term() -> term())
        ) :: t()
  def update_hook_slot(tree, fiber_id, slot_index, updater) do
    case Map.get(tree, fiber_id) do
      nil ->
        tree

      fiber ->
        new_slots = Map.update!(fiber.hook_slots, slot_index, updater)
        Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})
    end
  end
end
