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
    * `{:cell_retry, cell, subscriber, attempts}` — `use_value` couldn't reach
      the source; it subscribes afresh on the next render, which a timer or
      the source's process exiting triggers.
    * `:uninitialized` — slot never committed, or disabled mid-render.

  A `use_value` subscriber is `{owner_pid, fiber_id, slot_index, ref}`, where
  `ref` monitors the source's process when the transport names one.

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
    end_subscription(source, subscriber)
  end

  def cleanup({:cell_resubscribe, source, subscriber}), do: end_subscription(source, subscriber)
  def cleanup({:cell_retry, source, subscriber, _attempts}), do: end_subscription(source, subscriber)

  def cleanup(_other), do: :ok

  defp end_subscription(source, {_owner, _fiber_id, _slot, ref} = subscriber) do
    Process.demonitor(ref, [:flush])
    Filament.Cell.unsubscribe(source, subscriber)
  end

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

  @doc """
  The slot whose subscription `ref` monitors, made to subscribe afresh: its
  source's process exited.
  """
  @spec source_down(slot :: term(), reference()) :: {:ok, term()} | :error
  def source_down({:cell_subscribed, source, _raw, {_, _, _, ref} = subscriber, _projection, _value}, ref),
    do: {:ok, {:cell_retry, source, subscriber, 0}}

  def source_down({:cell_resubscribe, source, {_, _, _, ref} = subscriber}, ref),
    do: {:ok, {:cell_retry, source, subscriber, 0}}

  def source_down({:cell_retry, _source, {_, _, _, ref}, _attempts} = slot, ref), do: {:ok, slot}
  def source_down(_slot, _ref), do: :error
end
