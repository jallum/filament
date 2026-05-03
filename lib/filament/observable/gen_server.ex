defmodule Filament.Observable.GenServer do
  @moduledoc """
  Macro that makes a GenServer observable by Filament components.

  `use Filament.Observable.GenServer` injects:

    - `handle_call({:filament_subscribe, request, subscriber}, from, state)` —
      subscriber registration; calls `handle_subscribe/3` (overridable)
    - `handle_cast({:filament_unsubscribe, sub_key}, state)` —
      subscriber removal; calls `handle_unsubscribe/2` (overridable)
    - `handle_info({:DOWN, ref, :process, pid, reason}, state)` —
      automatic subscriber cleanup when a LiveView process terminates
    - `notify_observers/1` — call this from your handlers whenever state changes
      to push updates to all subscribed components

  > #### Do not mix with Hold.GenServer {: .warning}
  >
  > Do **not** use both `use Filament.Observable.GenServer` and
  > `use Filament.Hold.GenServer` in the same module. Both inject
  > `handle_info/2` for `{:DOWN, ref, :process, ...}` and the compiler will
  > raise a duplicate clause error. If you need both capabilities in one server,
  > use only `Filament.Observable.GenServer` and implement lock/hold management
  > manually in the server state.

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
        sub_key = {sub_info.pid, sub_info.fiber_id, sub_info.slot_index}

        # If the same fiber slot is re-subscribing (e.g. LiveView disconnected→connected
        # double-mount), cleanly replace the old subscriber so handle_subscribe/unsubscribe
        # are called exactly once per logical subscription and presence counts stay correct.
        subs = Process.get(:__filament_subscribers__, %{})

        {state, subs} =
          case Map.pop(subs, sub_key) do
            {nil, subs} ->
              {state, subs}

            {old_sub, subs} ->
              # Commit the removal to the process dict BEFORE calling handle_unsubscribe.
              # handle_unsubscribe may call notify_observers, which reads the process dict.
              # If the old sub is still in the dict at that point, notify_observers would
              # send an update to the dying subscriber, triggering a re-render + re-subscribe
              # cascade that inflates presence counts.
              Process.put(:__filament_subscribers__, subs)
              Process.demonitor(old_sub.ref, [:flush])
              {:ok, new_state} = handle_unsubscribe(old_sub, state)
              {new_state, subs}
          end

        ref = Process.monitor(sub_info.pid)
        subscriber = %Subscriber{sub_info | ref: ref, last_projected: :unset}

        # Use apply/3 to disable Elixir's strict type-checker from seeing
        # the concrete return type at compile time, preventing dead-branch
        # warnings in modules that override handle_subscribe with a fixed return.
        case apply(__MODULE__, :handle_subscribe, [request, subscriber, state]) do
          {:ok, initial_value, new_state} ->
            Process.put(:__filament_subscribers__, Map.put(subs, sub_key, subscriber))
            {:reply, {:ok, initial_value}, new_state}

          {:error, reason, new_state} ->
            Process.demonitor(ref, [:flush])
            {:reply, {:error, reason}, new_state}
        end
      end

      @impl true
      def handle_cast({:filament_unsubscribe, {_pid, _fiber_id, _slot_index} = sub_key}, state) do
        subs = Process.get(:__filament_subscribers__, %{})

        case Map.pop(subs, sub_key) do
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

        case Enum.find(subs, fn {_key, s} -> s.ref == ref end) do
          nil ->
            {:noreply, state}

          {sub_key, subscriber} ->
            new_subs = Map.delete(subs, sub_key)
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
          Map.new(subs, fn {sub_key, subscriber} ->
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
              {sub_key, subscriber}
            else
              new_projected = subscriber.project.(new_state)

              if new_projected !== subscriber.last_projected do
                send(
                  subscriber.pid,
                  {:filament_observable_update, subscriber.fiber_id, subscriber.slot_index,
                   new_projected}
                )

                {sub_key, %{subscriber | last_projected: new_projected}}
              else
                {sub_key, subscriber}
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
