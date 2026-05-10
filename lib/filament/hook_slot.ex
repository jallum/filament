defmodule Filament.HookSlot do
  @moduledoc """
  Operations on a single hook slot value.

  Each fiber stores its hooks in a `hook_slots` map keyed by slot index.
  The slot value's shape encodes which hook produced it:

    * `{value, setter}` — `use_state`. `setter` is a 1-arity fn or `nil`.
    * `{deps, cleanup}` — `use_effect`. `cleanup` is a 0-arity fn or `nil`.
      Disambiguated from the `use_state` shape by `cleanup`'s arity.
    * `{:cell_resolved, cell}` — `use_source` (resolved cell handle).
    * `{:cell_subscribed, cell, raw}` — `use_value` (subscribed + last raw).
    * `:uninitialized` — slot never committed, or disabled mid-render.
    * `:needs_resubscribe` — cell transport requested a resubscribe.

  This module owns pattern-matching on those shapes so consumer sites
  (the reconciler, the LV/LC adapters, the test harness) don't grow
  drive-by `case` expressions that drift apart over time. New hooks add
  one clause here instead of touching every site that walks `hook_slots`.
  """

  @type cleanup_ctx :: %{
          required(:owner_pid) => pid() | nil,
          required(:fiber_id) => String.t(),
          required(:slot_index) => non_neg_integer()
        }

  @doc """
  Run any cleanup associated with `slot` (effect cleanup fn, cell
  unsubscribe). Always returns `:ok`.
  """
  @spec cleanup(slot :: term(), cleanup_ctx()) :: :ok
  def cleanup({_deps, cleanup}, _ctx) when is_function(cleanup, 0) do
    cleanup.()
    :ok
  end

  def cleanup({:cell_subscribed, cell, _raw}, %{owner_pid: owner_pid, fiber_id: fiber_id, slot_index: slot_index})
      when not is_nil(cell) do
    Filament.Cell.unsubscribe(cell, {owner_pid, fiber_id, slot_index})
    :ok
  end

  def cleanup(_other, _ctx), do: :ok

  @doc """
  Walk every slot in a fiber's `hook_slots` map and run `cleanup/2` on
  each. The shared cleanup loop for unmount paths.
  """
  @spec cleanup_all(map(), pid() | nil, String.t()) :: :ok
  def cleanup_all(hook_slots, owner_pid, fiber_id) do
    Enum.each(hook_slots, fn {slot_index, slot} ->
      cleanup(slot, %{owner_pid: owner_pid, fiber_id: fiber_id, slot_index: slot_index})
    end)
  end

  @doc """
  Apply a new state value to a `use_state` slot, preserving the existing
  setter so closures captured in user code keep working across the update.
  """
  @spec put_state_value(slot :: term(), new_value :: term()) :: term()
  def put_state_value({_old_value, setter}, new_value) when is_function(setter, 1) do
    {new_value, setter}
  end

  def put_state_value(_other, new_value), do: {new_value, nil}

  @doc """
  Apply a new raw value to a `use_value` slot, preserving the existing
  cell identity so unsubscribe-on-cell-swap detection still works on
  the next render.
  """
  @spec put_cell_value(slot :: term(), new_raw :: term()) ::
          {:cell_subscribed, term() | nil, term()}
  def put_cell_value({:cell_subscribed, cell, _old}, new_raw) do
    {:cell_subscribed, cell, new_raw}
  end

  def put_cell_value(_other, new_raw), do: {:cell_subscribed, nil, new_raw}
end
