defmodule Filament.HookSlot do
  @moduledoc """
  Operations on a single hook slot value.

  Each fiber stores its hooks in a `hook_slots` map keyed by slot index.
  The slot value's shape encodes which hook produced it:

    * `{:state, value, setter, token}` — `use_state`. `token` identifies
      this mount, so a setter kept from an earlier one is ignored.
    * `{deps, cleanup}` — `use_effect`. `cleanup` is a 0-arity fn or `nil`.
    * `{:cell_resolved, cell}` — `use_source` (resolved cell handle).
    * `{:cell_subscribed, cell, raw, subscriber, projection, value}` — `use_value`;
      subscriber includes a generation token; `projection` and `value` are
      from the last render, so an update can tell whether the value changed.
    * `{:cell_resubscribe, cell, subscriber}` — refresh pending; retains cleanup identity.
    * `:uninitialized` — slot never committed, or disabled mid-render.

  This module owns pattern-matching on those shapes so consumer sites
  (the reconciler, the LV/LC adapters, the test harness) don't grow
  drive-by `case` expressions that drift apart over time. New hooks add
  one clause here instead of touching every site that walks `hook_slots`.
  """

  @doc """
  Run any cleanup associated with `slot` (effect cleanup fn, cell
  unsubscribe). Always returns `:ok`.
  """
  @spec cleanup(slot :: term()) :: :ok
  def cleanup({_deps, cleanup}) when is_function(cleanup, 0) do
    cleanup.()
    :ok
  end

  def cleanup({:cell_subscribed, source, _raw, subscriber, _projection, _value}) do
    Filament.Cell.unsubscribe(source, subscriber)
  end

  def cleanup({:cell_resubscribe, source, subscriber}) do
    Filament.Cell.unsubscribe(source, subscriber)
  end

  def cleanup(_other), do: :ok

  @doc """
  Run `cleanup/1` on every slot in a fiber's `hook_slots` map. The shared
  cleanup loop for unmount paths.
  """
  @spec cleanup_all(map()) :: :ok
  def cleanup_all(hook_slots), do: Enum.each(hook_slots, fn {_index, slot} -> cleanup(slot) end)

  @doc """
  Apply a new raw value to a `use_value` slot, preserving the existing
  source identity so unsubscribe-on-source-swap detection still works on
  the next render. The raw value is always kept; the result says whether
  the last render's projection now gives a different value.
  """
  @spec put_cell_value(slot :: term(), new_raw :: term()) :: {term(), changed? :: boolean()}
  def put_cell_value({:cell_subscribed, source, _old, subscriber, projection, value}, new_raw) do
    new_value = projection.(new_raw)
    {{:cell_subscribed, source, new_raw, subscriber, projection, new_value}, new_value !== value}
  end

  @doc false
  def matches_subscriber?({:cell_subscribed, _source, _raw, subscriber, _projection, _value}, subscriber), do: true
  def matches_subscriber?(_slot, _subscriber), do: false

  @doc false
  def resubscribe({:cell_subscribed, source, _raw, subscriber, _projection, _value}, subscriber) do
    {:cell_resubscribe, source, subscriber}
  end
end
