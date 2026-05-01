defmodule Filament.Observable.GenServer do
  @moduledoc """
  Macro that makes a GenServer observable.

  Usage:

      defmodule MyServer do
        use Filament.Observable.GenServer

        def init(args), do: {:ok, %{count: 0}}

        # Optional — override to control subscription acceptance:
        @impl Filament.Observable
        def handle_subscribe(_request, _subscriber, state), do: {:ok, state, state}

        # Optional — override to run teardown on unsubscribe:
        @impl Filament.Observable
        def handle_unsubscribe(_subscriber, state), do: {:ok, state}

        def handle_call(:increment, _from, state) do
          new_state = %{state | count: state.count + 1}
          notify_observers(new_state)
          {:reply, :ok, new_state}
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Filament.Observable

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
        subscriber_pid = sub_info.pid
        ref = Process.monitor(subscriber_pid)

        subscriber = %Subscriber{
          sub_info
          | ref: ref,
            last_projected: :unset
        }

        # Use apply/3 to disable Elixir's strict type-checker from seeing
        # the concrete return type at compile time, preventing dead-branch
        # warnings in modules that override handle_subscribe with a fixed return.
        case apply(__MODULE__, :handle_subscribe, [request, subscriber, state]) do
          {:ok, initial_value, new_state} ->
            subs = Process.get(:__filament_subscribers__, %{})
            Process.put(:__filament_subscribers__, Map.put(subs, subscriber_pid, subscriber))
            {:reply, {:ok, initial_value}, new_state}

          {:error, reason, new_state} ->
            Process.demonitor(ref, [:flush])
            {:reply, {:error, reason}, new_state}
        end
      end

      @impl true
      def handle_cast({:filament_unsubscribe, pid}, state) do
        subs = Process.get(:__filament_subscribers__, %{})

        case Map.pop(subs, pid) do
          {nil, _subs} ->
            {:noreply, state}

          {subscriber, new_subs} ->
            Process.demonitor(subscriber.ref, [:flush])
            Process.put(:__filament_subscribers__, new_subs)
            {:ok, new_state} = handle_unsubscribe(subscriber, state)
            {:noreply, new_state}
        end
      end

      @impl true
      def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
        subs = Process.get(:__filament_subscribers__, %{})

        case Enum.find(subs, fn {_pid, s} -> s.ref == ref end) do
          nil ->
            {:noreply, state}

          {pid, subscriber} ->
            new_subs = Map.delete(subs, pid)
            Process.put(:__filament_subscribers__, new_subs)
            {:ok, new_state} = handle_unsubscribe(subscriber, state)
            {:noreply, new_state}
        end
      end

      # ── notify_observers/1 ───────────────────────────────────────────────

      @max_mailbox_depth Application.compile_env(:filament, :observable_max_mailbox_depth, 100)

      @doc """
      Notify all subscribers of a new state value.

      Sends `{:filament_observable_update, fiber_id, slot_index, projected_value}`
      to each subscriber's LiveView process.

      Call this from your `handle_call`/`handle_cast`/`handle_info` whenever
      state changes and subscribers should re-render.
      """
      @spec notify_observers(new_state :: term()) :: :ok
      def notify_observers(new_state) do
        subs = Process.get(:__filament_subscribers__, %{})

        new_subs =
          Map.new(subs, fn {pid, subscriber} ->
            depth_result = Process.info(subscriber.pid, :message_queue_len)

            if saturated?(depth_result) do
              require Logger

              depth_str =
                case depth_result do
                  nil -> "dead"
                  {:message_queue_len, n} -> "#{n}"
                end

              Logger.warning(
                "[Filament.Observable] subscriber #{inspect(subscriber.pid)} " <>
                  "mailbox saturated (depth=#{depth_str}/#{@max_mailbox_depth}), " <>
                  "dropping update for fiber #{inspect(subscriber.fiber_id)} slot #{subscriber.slot_index}"
              )

              send(
                subscriber.pid,
                {:filament_observable_resubscribe, subscriber.fiber_id, subscriber.slot_index}
              )

              # Do NOT update last_projected — next real notification must fire
              {pid, subscriber}
            else
              new_projected = subscriber.project.(new_state)

              if new_projected !== subscriber.last_projected do
                send(
                  subscriber.pid,
                  {:filament_observable_update, subscriber.fiber_id, subscriber.slot_index,
                   new_projected}
                )

                {pid, %{subscriber | last_projected: new_projected}}
              else
                {pid, subscriber}
              end
            end
          end)

        Process.put(:__filament_subscribers__, new_subs)
        :ok
      end

      defp saturated?(nil), do: true
      defp saturated?({:message_queue_len, n}) when n >= @max_mailbox_depth, do: true
      defp saturated?(_), do: false
    end
  end
end
