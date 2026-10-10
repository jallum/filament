defmodule Filament.Bench.Compat do
  @moduledoc false
  @substrate Code.ensure_loaded?(Filament.Source)
  @compiled_web Code.ensure_loaded?(Filament.Template)
  @direct_web Code.ensure_loaded?(Filament.Web) and function_exported?(Filament.Web, :render, 2)

  @implementation (cond do
                     @compiled_web -> "cell-web-compiled"
                     @direct_web -> "cell-web-direct"
                     @substrate -> "cell-vnode"
                     true -> "observable-rendered"
                   end)
  def implementation, do: @implementation

  def render_options do
    if @compiled_web or @direct_web, do: [owner_pid: self(), target: Filament.Web], else: [owner_pid: self()]
  end

  if @substrate do
    def read(server),
      do: Filament.Hooks.use_value(Filament.Source.new(Filament.Observable.GenServer, server), &Function.identity/1)

    def rendered(value), do: Filament.Web.to_rendered(value)

    if Code.ensure_loaded?(Filament.LiveView) and function_exported?(Filament.LiveView, :apply_message, 2) do
      def apply_message(tree, {:cell_update, _, _} = message), do: {rerender(tree, message), 1}
      def apply_message(tree, {:cell_updates, updates} = message), do: {rerender(tree, message), length(updates)}
      def apply_message(_tree, message), do: raise("unexpected transport message: #{inspect(message)}")

      defp rerender(tree, message) do
        {:rerender, updated} = Filament.LiveView.apply_message(tree, message)
        updated
      end
    else
      def apply_message(tree, {:cell_update, subscriber, value}) do
        {:ok, updated, _} = Filament.LiveView.apply_cell_update(tree, subscriber, value)
        {updated, 1}
      end

      def apply_message(tree, {:cell_updates, updates}) do
        {:ok, updated, _} = Filament.LiveView.apply_cell_updates(tree, updates)
        {updated, length(updates)}
      end

      def apply_message(_tree, message), do: raise("unexpected transport message: #{inspect(message)}")
    end

    def subscription_count do
      map_size(Process.get(:__filament_cell_subscribers__, %{}))
    end
  else
    def read(server), do: Filament.Hooks.use_observable(server, &Function.identity/1)
    def rendered(value), do: value

    def apply_message(tree, {:filament_observable_updates, updates}) do
      updated =
        case Filament.LiveView.apply_observable_updates(tree, updates) do
          {updated, _changed?} -> updated
          updated when is_map(updated) -> updated
        end

      {updated, length(updates)}
    end

    def apply_message(_tree, message), do: raise("unexpected transport message: #{inspect(message)}")

    def subscription_count do
      :__filament_subscribers__
      |> Process.get(%{})
      |> Enum.reduce(0, fn {_, subscriber}, count -> count + map_size(subscriber.proj_keys) end)
    end
  end

  # use_state slots are {:state, value, setter, token} since 0.6 and
  # {value, setter} before; the setter message carries the value last.
  def setter({:state, _value, setter, _token}), do: setter
  def setter({_value, setter}), do: setter

  # Writes a use_state slot as its setter's message would, marking the fiber
  # dirty where components render only when their inputs change.
  def put_state(tree, fiber_id, slot, value) do
    tree
    |> update_in([fiber_id, Access.key!(:hook_slots), slot], &put_slot_value(&1, value))
    |> mark_dirty(fiber_id)
  end

  defp put_slot_value({:state, _, setter, token}, value), do: {:state, value, setter, token}
  defp put_slot_value({_, setter}, value), do: {value, setter}

  if Code.ensure_loaded?(Filament.Reconciler) and function_exported?(Filament.Reconciler, :mark_dirty, 2) do
    defp mark_dirty(tree, fiber_id), do: Filament.Reconciler.mark_dirty(tree, fiber_id)
  else
    defp mark_dirty(tree, _fiber_id), do: tree
  end

  def drain(tree, messages \\ 0, updates \\ 0) do
    receive do
      message
      when is_tuple(message) and elem(message, 0) in [:cell_update, :cell_updates, :filament_observable_updates] ->
        {tree, count} = apply_message(tree, message)
        drain(tree, messages + 1, updates + count)

      {:cell_resubscribe, _} ->
        raise "benchmark saturated the owner mailbox"

      {:filament_observable_resubscribe, _, _} ->
        raise "benchmark saturated the owner mailbox"
    after
      0 -> {tree, messages, updates}
    end
  end
end
