defmodule Filament.FiberTree do
  @moduledoc false

  @type t :: %{String.t() => Filament.Fiber.t()}

  @doc """
  Look up the event handler at `handler_index` for the fiber with `fiber_id`.
  Defaults to the bubble phase; pass `:capture` for capture-phase handlers.
  Returns the handler function or nil if not found.
  """
  @spec get_event_handler(t(), String.t(), non_neg_integer()) :: function() | nil
  @spec get_event_handler(t(), String.t(), non_neg_integer(), :bubble | :capture) ::
          function() | nil
  def get_event_handler(tree, fiber_id, handler_index, phase \\ :bubble) when phase in [:bubble, :capture] do
    case Map.get(tree, fiber_id) do
      nil -> nil
      fiber -> Map.get(handler_map_for(fiber, phase), handler_index)
    end
  end

  defp handler_map_for(fiber, :bubble), do: fiber.event_handlers
  defp handler_map_for(fiber, :capture), do: fiber.capture_handlers || %{}

  @doc """
  Returns all fiber IDs present in the tree.
  """
  @spec fiber_ids(t()) :: [String.t()]
  def fiber_ids(tree), do: Map.keys(tree)

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
