defmodule Filament.Core do
  @moduledoc """
  Target-agnostic substrate primitives shared by every Filament backend.

  Today this exposes the capture/bubble event dispatcher
  (`dispatch_event/4`, `stop_propagation/1`). Backends contribute event
  sources — DOM events for the web adapter, terminal escape sequences for
  TUI, etc. — and feed them into the dispatcher; event semantics
  (ancestor walk, propagation control) live here.
  """

  alias Filament.FiberTree

  @type tree :: FiberTree.t()
  @type fiber_id :: String.t()
  @type slot :: non_neg_integer()
  @type params :: map()

  @doc """
  Dispatch an event to a target fiber.

  Walks the fiber ancestry root-to-target running each ancestor's
  capture-phase handlers, then runs the target's bubble-phase handler at
  `target_slot`. Returns `{:ok, :dispatched}` on a normal walk,
  `{:ok, {:stopped, value}}` if a handler called `stop_propagation/1`, or
  `{:error, :no_target}` if the target fiber doesn't exist.

  Handler arity:

    * 0-arity (`fn -> ... end`) — invoked with no args.
    * 1-arity (`fn params -> ... end`) — receives `params`.

  Side effects from handlers (state setters, observable writes) propagate
  through the runtime as usual; this dispatcher just runs the handlers in
  walk order.
  """
  @spec dispatch_event(tree(), fiber_id(), slot(), params()) ::
          {:ok, :dispatched} | {:ok, {:stopped, term()}} | {:error, :no_target}
  def dispatch_event(tree, target_fiber_id, target_slot, params \\ %{}) do
    case Map.get(tree, target_fiber_id) do
      nil ->
        {:error, :no_target}

      target ->
        try do
          run_capture_phase(tree, ancestor_path(tree, target_fiber_id), params)
          run_target_handler(target, target_slot, params)
          {:ok, :dispatched}
        catch
          {:filament_stop_propagation, value} -> {:ok, {:stopped, value}}
        end
    end
  end

  @doc """
  Halt event propagation. Called from inside an event handler. The walker
  catches this and returns `{:ok, {:stopped, value}}`.
  """
  @spec stop_propagation(term()) :: no_return()
  def stop_propagation(value) do
    throw({:filament_stop_propagation, value})
  end

  # Build the path from root down to the target's parent: [root_id, ...,
  # target_parent_id]. Recursion prepends each parent to the accumulator,
  # which natively yields root-first order (parent of leaf gets prepended
  # first, then leaf's grandparent, ..., then root last in the call order
  # — but as the deepest call, it sits at the head of the final list).
  defp ancestor_path(tree, target_fiber_id), do: ancestor_chain(target_fiber_id, tree, [])

  defp ancestor_chain(fiber_id, tree, acc) do
    case Map.get(tree, fiber_id) do
      nil -> acc
      %{parent_id: nil} -> acc
      %{parent_id: parent_id} -> ancestor_chain(parent_id, tree, [parent_id | acc])
    end
  end

  defp run_capture_phase(tree, ancestor_ids, params) do
    Enum.each(ancestor_ids, fn id ->
      tree
      |> Map.fetch!(id)
      |> capture_handlers()
      |> Enum.each(&invoke(&1, params))
    end)
  end

  defp capture_handlers(%{capture_handlers: handlers}) when is_map(handlers) do
    Map.values(handlers)
  end

  defp capture_handlers(_fiber), do: []

  defp run_target_handler(target, target_slot, params) do
    case Map.get(target.event_handlers || %{}, target_slot) do
      nil -> :ok
      handler -> invoke(handler, params)
    end
  end

  defp invoke(handler, _params) when is_function(handler, 0), do: handler.()
  defp invoke(handler, params) when is_function(handler, 1), do: handler.(params)
  defp invoke(_, _), do: :ok
end
