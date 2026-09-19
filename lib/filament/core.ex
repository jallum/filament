defmodule Filament.Core do
  @moduledoc """
  Target-agnostic substrate primitives shared by every Filament backend.

  Today this exposes the capture/bubble event dispatcher
  (`dispatch_event/5`, `stop_propagation/1`). Backends contribute event
  sources — DOM events for the web adapter, terminal escape sequences for
  TUI, etc. — and feed them into the dispatcher; event semantics
  (ancestor walk, propagation control, kinds filtering) live here.
  """

  alias Filament.FiberTree

  @type tree :: FiberTree.t()
  @type fiber_id :: String.t()
  @type slot :: non_neg_integer()
  @type params :: map()
  @type kind :: atom()

  @doc """
  Dispatch an event to a target fiber.

  Walks the fiber ancestry root-to-target running each ancestor's
  capture-phase handlers, then runs the target's bubble-phase handler at
  `target_slot`. Returns `{:ok, :dispatched}` on a normal walk,
  `{:ok, {:stopped, value}}` if a handler called `stop_propagation/1`, or
  `{:error, :no_target}` if the target fiber doesn't exist.

  The optional `kind` arg lets the dispatcher filter handlers by the
  kinds-set they registered with. A handler at slot `i` runs only if
  `fiber.event_handler_kinds[i]` is `:all` (or missing) or contains
  `kind`. Capture handlers are filtered symmetrically via
  `capture_handler_kinds`. Defaults to `:all` — backwards compatible:
  every handler fires.

  Handler arity:

    * 0-arity (`fn -> ... end`) — invoked with no args.
    * 1-arity (`fn params -> ... end`) — receives `params`.
  """
  @spec dispatch_event(tree(), fiber_id(), slot(), params(), kind()) ::
          {:ok, :dispatched} | {:ok, {:stopped, term()}} | {:error, :no_target}
  def dispatch_event(tree, target_fiber_id, target_slot, params \\ %{}, kind \\ :all) do
    case Map.get(tree, target_fiber_id) do
      nil ->
        {:error, :no_target}

      target ->
        try do
          run_capture_phase(tree, ancestor_path(tree, target_fiber_id), params, kind)
          run_target_handler(target, target_slot, params, kind)
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
  # target_parent_id]. Recursion prepends each parent to the accumulator.
  defp ancestor_path(tree, target_fiber_id), do: ancestor_chain(target_fiber_id, tree, [])

  defp ancestor_chain(fiber_id, tree, acc) do
    case Map.get(tree, fiber_id) do
      nil -> acc
      %{parent_id: nil} -> acc
      %{parent_id: parent_id} -> ancestor_chain(parent_id, tree, [parent_id | acc])
    end
  end

  defp run_capture_phase(tree, ancestor_ids, params, kind) do
    Enum.each(ancestor_ids, fn id ->
      fiber = Map.fetch!(tree, id)
      handlers = fiber.capture_handlers || %{}
      kinds_map = Map.get(fiber, :capture_handler_kinds, %{}) || %{}

      Enum.each(handlers, fn {slot, handler} ->
        slot_kinds = Map.get(kinds_map, slot, :all)
        if kind_matches?(slot_kinds, kind), do: invoke(handler, params)
      end)
    end)
  end

  defp run_target_handler(target, target_slot, params, kind) do
    case Map.get(target.event_handlers || %{}, target_slot) do
      nil ->
        :ok

      handler ->
        kinds_map = Map.get(target, :event_handler_kinds, %{}) || %{}
        slot_kinds = Map.get(kinds_map, target_slot, :all)
        if kind_matches?(slot_kinds, kind), do: invoke(handler, params), else: :ok
    end
  end

  # Dispatch kind :all is a wildcard from the dispatcher side: it fires
  # every handler regardless of what kinds-set the handler registered
  # with (back-compat for callers that haven't adopted kinds).
  # Handler kinds :all is a wildcard from the handler side: it fires for
  # every dispatched kind.
  defp kind_matches?(:all, _kind), do: true
  defp kind_matches?(_slot_kinds, :all), do: true

  defp kind_matches?(%MapSet{} = slot_kinds, kind),
    do: MapSet.member?(slot_kinds, kind)

  defp kind_matches?(_slot_kinds, _kind), do: false

  defp invoke(handler, _params) when is_function(handler, 0), do: handler.()
  defp invoke(handler, params) when is_function(handler, 1), do: handler.(params)
  defp invoke(_, _), do: :ok
end
