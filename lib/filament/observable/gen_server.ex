defmodule Filament.Observable.GenServer do
  @moduledoc """
  Macro that makes a GenServer observable by Filament components.

  `use Filament.Observable.GenServer` injects:

    - `handle_call({:filament_subscribe, request, subscriber}, from, state)` —
      subscriber registration; calls `handle_subscribe/3` (overridable)
    - `handle_cast({:filament_remove_projection, sub_key, proj_key}, state)` —
      projection removal; auto-unsubscribes when the last projection is removed
    - `handle_info({:DOWN, ref, :process, pid, reason}, state)` —
      automatic subscriber cleanup when a LiveView process terminates
    - `notify_observers/1` — call this from your handlers whenever state changes
      to push updates to all subscribed components

  Subscribers are keyed by `{owner_pid, request}`. All fibers within the same
  LiveView that subscribe to the same server with the same request share one
  subscriber entry. Each fiber registers a named projection; `notify_observers/1`
  runs all projections, deduplicates by `last_projected`, and delivers one
  `{:filament_observable_updates, [{fiber_id, slot_index, value}]}` message per
  subscriber (only including projections whose value changed).

  ## Example

      defmodule MyApp.Counter do
        use Filament.Observable.GenServer

        def start_link(opts \\\\ []) do
          GenServer.start_link(__MODULE__, 0, name: Keyword.get(opts, :name, __MODULE__))
        end

        @impl GenServer
        def init(initial), do: {:ok, initial}

        @impl Filament.Observable
        def handle_subscribe(_request, _subscriber, state) do
          {:ok, state, state}
        end

        @impl GenServer
        def handle_call(:increment, _from, count) do
          new_count = count + 1
          notify_observers(new_count)
          {:reply, new_count, new_count}
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Filament.Observable

      use GenServer

      alias Filament.Observable.Subscriber

      # ── Default Observable callbacks (overridable) ───────────────────────

      @impl Filament.Observable
      def handle_subscribe(_request, _subscriber, state), do: {:ok, state, state}

      @impl Filament.Observable
      def handle_unsubscribe(_subscriber, state), do: {:ok, state}

      defoverridable handle_subscribe: 3, handle_unsubscribe: 2

      # ── Injected GenServer message handlers ──────────────────────────────

      @impl true
      def handle_call({:filament_subscribe, request, %Subscriber{} = sub_info}, _from, state) do
        sub_key = {sub_info.pid, sub_info.request}
        subs = Process.get(:__filament_subscribers__, %{})

        case Map.get(subs, sub_key) do
          nil ->
            ref = Process.monitor(sub_info.pid)
            subscriber = %{sub_info | ref: ref}

            case apply(__MODULE__, :handle_subscribe, [request, subscriber, state]) do
              {:ok, initial_value, new_state} ->
                Process.put(:__filament_subscribers__, Map.put(subs, sub_key, subscriber))
                {:reply, {:ok, initial_value}, new_state}

              {:error, reason, new_state} ->
                Process.demonitor(ref, [:flush])
                {:reply, {:error, reason}, new_state}
            end

          existing ->
            merged = %{existing | projections: Map.merge(existing.projections, sub_info.projections)}
            Process.put(:__filament_subscribers__, Map.put(subs, sub_key, merged))
            {:reply, {:ok, state}, state}
        end
      end

      @impl true
      def handle_cast({:filament_remove_projection, sub_key, proj_key}, state) do
        subs = Process.get(:__filament_subscribers__, %{})

        case Map.get(subs, sub_key) do
          nil ->
            {:noreply, state}

          subscriber ->
            new_projections = Map.delete(subscriber.projections, proj_key)

            if map_size(new_projections) == 0 do
              Process.demonitor(subscriber.ref, [:flush])
              Process.put(:__filament_subscribers__, Map.delete(subs, sub_key))
              {:ok, new_state} = handle_unsubscribe(subscriber, state)
              {:noreply, new_state}
            else
              updated = %{subscriber | projections: new_projections}
              Process.put(:__filament_subscribers__, Map.put(subs, sub_key, updated))
              {:noreply, state}
            end
        end
      end

      @impl true
      def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
        subs = Process.get(:__filament_subscribers__, %{})

        case Enum.find(subs, fn {_key, s} -> s.ref == ref end) do
          nil ->
            {:noreply, state}

          {sub_key, subscriber} ->
            Process.put(:__filament_subscribers__, Map.delete(subs, sub_key))
            {:ok, new_state} = handle_unsubscribe(subscriber, state)
            {:noreply, new_state}
        end
      end

      # ── notify_observers/1 ───────────────────────────────────────────────

      @max_mailbox_depth Application.compile_env(:filament, :observable_max_mailbox_depth, 100)

      @doc """
      Notify all subscribers of a new state value.

      For each unique subscriber (LiveView process + request), runs all registered
      projections, collects the ones whose value changed, and sends one
      `{:filament_observable_updates, [{fiber_id, slot_index, value}]}` message.

      Call this from your `handle_call`/`handle_cast`/`handle_info` whenever
      state changes and subscribers should re-render.
      """
      @spec notify_observers(new_state :: term()) :: :ok
      def notify_observers(new_state) do
        subs = Process.get(:__filament_subscribers__, %{})
        new_subs = Filament.Observable.GenServer.notify_each(subs, new_state, @max_mailbox_depth)
        Process.put(:__filament_subscribers__, new_subs)
        :ok
      end
    end
  end

  @doc false
  def notify_each(subs, new_state, max_mailbox_depth) do
    Map.new(subs, fn {sub_key, subscriber} ->
      depth_result = Process.info(subscriber.pid, :message_queue_len)
      {sub_key, notify_subscriber(subscriber, new_state, depth_result, max_mailbox_depth)}
    end)
  end

  defp notify_subscriber(subscriber, new_state, depth_result, max_mailbox_depth) do
    if saturated_depth?(depth_result, max_mailbox_depth) do
      log_and_resubscribe(subscriber, depth_result, max_mailbox_depth)
      subscriber
    else
      {new_projections, updates} = collect_updates(subscriber.projections, new_state)

      if updates != [] do
        send(subscriber.pid, {:filament_observable_updates, updates})
      end

      %{subscriber | projections: new_projections}
    end
  end

  defp collect_updates(projections, new_state) do
    Enum.reduce(projections, {%{}, []}, fn {{fid, si} = key, {fun, last}}, {proj_acc, upd_acc} ->
      new_val = fun.(new_state)
      updated_proj = Map.put(proj_acc, key, {fun, new_val})

      if new_val === last do
        {updated_proj, upd_acc}
      else
        {updated_proj, [{fid, si, new_val} | upd_acc]}
      end
    end)
  end

  defp saturated_depth?(nil, _max), do: true
  defp saturated_depth?({:message_queue_len, n}, max) when n >= max, do: true
  defp saturated_depth?(_, _), do: false

  defp log_and_resubscribe(subscriber, depth_result, max_mailbox_depth) do
    require Logger

    depth_str =
      case depth_result do
        nil -> "dead"
        {:message_queue_len, n} -> "#{n}"
      end

    Logger.warning(
      "[Filament.Observable] subscriber #{inspect(subscriber.pid)} " <>
        "mailbox saturated (depth=#{depth_str}/#{max_mailbox_depth}), " <>
        "dropping update"
    )

    Enum.each(subscriber.projections, fn {{fid, si}, _} ->
      send(subscriber.pid, {:filament_observable_resubscribe, fid, si})
    end)

    subscriber
  end
end
