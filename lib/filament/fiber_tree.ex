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
         do: Map.get(handler_map_for(fiber, phase), handler_index)
  end

  defp handler_map_for(fiber, :bubble), do: fiber.event_handlers
  defp handler_map_for(fiber, :capture), do: fiber.capture_handlers

  # A wire ref's fiber id and handler index (`Filament.Hooks.register_event_handler/1`).
  # The index is digits only, so the last colon is the separator, whatever
  # the fiber id holds: a keyed child's key may have colons of its own.
  @spec parse_event_ref(String.t()) :: {:ok, String.t(), non_neg_integer()} | :error
  def parse_event_ref(ref) when is_binary(ref) do
    case :binary.matches(ref, ":") do
      [] ->
        :error

      matches ->
        {at, 1} = List.last(matches)
        index = binary_part(ref, at + 1, byte_size(ref) - at - 1)

        case Integer.parse(index) do
          {idx, ""} when idx >= 0 -> {:ok, binary_part(ref, 0, at), idx}
          _ -> :error
        end
    end
  end

  @doc """
  Returns all fiber IDs present in the tree.
  """
  @spec fiber_ids(t()) :: [String.t()]
  def fiber_ids(tree), do: Map.keys(tree)
end
