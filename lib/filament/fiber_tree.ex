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
    with %{} = fiber <- Map.get(tree, fiber_id),
         {handler, _kinds} <- Map.get(handler_map_for(fiber, phase), handler_index) do
      handler
    end
  end

  defp handler_map_for(fiber, :bubble), do: fiber.event_handlers
  defp handler_map_for(fiber, :capture), do: fiber.capture_handlers

  @doc """
  Returns all fiber IDs present in the tree.
  """
  @spec fiber_ids(t()) :: [String.t()]
  def fiber_ids(tree), do: Map.keys(tree)
end
