defmodule Filament.Bench.Compat do
  @moduledoc false
  @substrate Code.ensure_loaded?(Filament.Source)

  def implementation, do: if(@substrate, do: "cell-vnode", else: "observable-rendered")

  if @substrate do
    def read(server),
      do: Filament.Hooks.use_value(Filament.Source.new(Filament.Observable.GenServer, server), &Function.identity/1)

    def rendered(value), do: Filament.Web.to_rendered(value)

    def apply_message(tree, {:cell_update, subscriber, value}) do
      {:ok, updated, _} = Filament.LiveView.apply_cell_update(tree, subscriber, value)
      {updated, 1}
    end

    def apply_message(tree, {:cell_updates, updates}) do
      {:ok, updated, _} = Filament.LiveView.apply_cell_updates(tree, updates)
      {updated, length(updates)}
    end

    def apply_message(_tree, message), do: raise("unexpected transport message: #{inspect(message)}")

    def subscription_count do
      map_size(Process.get(:__filament_cell_subscribers__, %{}))
    end
  else
    def read(server), do: Filament.Hooks.use_observable(server, &Function.identity/1)
    def rendered(value), do: value

    def apply_message(tree, {:filament_observable_updates, updates}) do
      {Filament.LiveView.apply_observable_updates(tree, updates), length(updates)}
    end

    def apply_message(_tree, message), do: raise("unexpected transport message: #{inspect(message)}")

    def subscription_count do
      :__filament_subscribers__
      |> Process.get(%{})
      |> Enum.reduce(0, fn {_, subscriber}, count -> count + map_size(subscriber.proj_keys) end)
    end
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
