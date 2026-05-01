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

        case handle_subscribe(request, subscriber, state) do
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

        for {_pid, subscriber} <- subs do
          projected = subscriber.project.(new_state)

          send(
            subscriber.pid,
            {:filament_observable_update, subscriber.fiber_id, subscriber.slot_index, projected}
          )
        end

        :ok
      end
    end
  end
end
