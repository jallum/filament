defmodule Filament.Observable.GenServer do
  @moduledoc """
  Macro that makes a GenServer observable by Filament components.

  `use Filament.Observable.GenServer` injects:

    - `handle_call({:filament_subscribe, subscriber}, from, state)` —
      subscriber registration; calls `handle_subscribe/2` (overridable)
    - `handle_cast({:filament_remove_projection, owner_pid, proj_key}, state)` —
      projection removal; auto-unsubscribes when the last projection is removed
    - `handle_info({:DOWN, ref, :process, pid, reason}, state)` —
      automatic subscriber cleanup when a LiveView process terminates
    - `notify_observers/1` — call this from your handlers whenever state changes
      to push raw state to all subscribed components

  Subscribers are keyed by `owner_pid`. All fibers within the same LiveView that
  subscribe to the same server share one subscriber entry. Each fiber registers a
  named projection key; `notify_observers/1` sends one
  `{:filament_observable_updates, [{fiber_id, slot_index, raw_state}]}` message
  per subscriber whenever the raw state changes (change-or-bust at subscriber level).
  Projection fns run client-side on each re-render, so closures over local component
  state (filters, selections, etc.) always see the current value.

  ## Example

      defmodule MyApp.Counter do
        use Filament.Observable.GenServer

        def start_link(opts \\\\ []) do
          GenServer.start_link(__MODULE__, 0, name: Keyword.get(opts, :name, __MODULE__))
        end

        @impl GenServer
        def init(initial), do: {:ok, initial}

        @impl Filament.Observable
        def handle_subscribe(_subscriber, state) do
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

  @behaviour Filament.Cell

  # ── Cell behaviour: GenServer transport ─────────────────────────────────────
  #
  # Lets a GenServer-backed observable be addressed as a Cell:
  #
  #     cell = {Filament.Observable.GenServer, server_pid_or_name}
  #     {:ok, value} = Filament.Cell.subscribe(cell, subscriber, projection)
  #
  # Cell-style subscribers live alongside the legacy `Subscriber{}` model in
  # the GenServer's process dictionary; both notification paths fire from
  # `notify_observers/1`.

  @impl Filament.Cell
  def subscribe(server, subscriber, projection) when is_function(projection, 1) do
    GenServer.call(server, {:filament_cell_subscribe, subscriber, projection})
  catch
    :exit, _ -> :disconnected
  end

  @impl Filament.Cell
  def unsubscribe(server, subscriber) do
    GenServer.cast(server, {:filament_cell_unsubscribe, subscriber})
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl Filament.Cell
  def current(server, projection) when is_function(projection, 1) do
    GenServer.call(server, {:filament_cell_current, projection})
  catch
    :exit, _ -> :disconnected
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Filament.Observable

      use GenServer

      alias Filament.Observable.Subscriber

      # ── Default Observable callbacks (overridable) ───────────────────────

      @impl Filament.Observable
      def handle_subscribe(_subscriber, state), do: {:ok, state, state}

      @impl Filament.Observable
      def handle_unsubscribe(_subscriber, state), do: {:ok, state}

      defoverridable handle_subscribe: 2, handle_unsubscribe: 2

      # ── Injected GenServer message handlers ──────────────────────────────

      # Cell.subscribe / unsubscribe / current — handled via thin stubs that
      # delegate to module-level helpers in `Filament.Observable.GenServer`,
      # keeping the injected quote block short.
      @impl true
      def handle_call({:filament_cell_subscribe, subscriber, projection}, from, state) do
        Filament.Observable.GenServer.handle_cell_subscribe(
          __MODULE__,
          subscriber,
          projection,
          from,
          state
        )
      end

      @impl true
      def handle_call({:filament_cell_current, projection}, from, state) do
        Filament.Observable.GenServer.handle_cell_current(__MODULE__, projection, from, state)
      end

      @impl true
      def handle_cast({:filament_cell_unsubscribe, subscriber}, state) do
        Filament.Observable.GenServer.handle_cell_unsubscribe(subscriber, state)
      end

      @impl true
      def handle_call({:filament_subscribe, %Subscriber{} = sub_info}, _from, state) do
        Filament.Observable.GenServer.handle_legacy_subscribe(__MODULE__, sub_info, state)
      end

      @impl true
      def handle_cast({:filament_remove_projection, sub_key, proj_key}, state) do
        Filament.Observable.GenServer.handle_legacy_remove_projection(
          __MODULE__,
          sub_key,
          proj_key,
          state
        )
      end

      @impl true
      def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
        subs = Process.get(:__filament_subscribers__, %{})

        case Enum.find(subs, fn {_key, s} -> s.ref == ref end) do
          nil ->
            {:noreply, state}

          {sub_key, subscriber} ->
            Process.put(:__filament_subscribers__, Map.delete(subs, sub_key))
            Filament.Observable.GenServer.delete_session_index(subscriber.session_token)
            {:ok, new_state} = handle_unsubscribe(subscriber, state)
            {:noreply, new_state}
        end
      end

      # ── notify_observers/1 ───────────────────────────────────────────────

      @max_mailbox_depth Application.compile_env(:filament, :observable_max_mailbox_depth, 100)

      @doc """
      Notify all subscribers of a new state value.

      For each unique subscriber (LiveView process), if the raw state changed,
      sends one `{:filament_observable_updates, [{fiber_id, slot_index, raw_state}]}`
      message covering all registered projection keys. Projection fns run client-side
      at render time so closures over local component state always see current values.

      Call this from your `handle_call`/`handle_cast`/`handle_info` whenever
      state changes and subscribers should re-render.
      """
      @spec notify_observers(new_state :: term()) :: :ok
      def notify_observers(new_state) do
        # Legacy Subscriber{}-keyed path
        subs = Process.get(:__filament_subscribers__, %{})
        new_subs = Filament.Observable.GenServer.notify_each(subs, new_state, @max_mailbox_depth)
        Process.put(:__filament_subscribers__, new_subs)

        # Cell-style subscribers — change-or-bust on the projected value
        cell_subs = Process.get(:__filament_cell_subscribers__, %{})

        new_cell_subs =
          Filament.Observable.GenServer.notify_cell_each(cell_subs, new_state, @max_mailbox_depth)

        Process.put(:__filament_cell_subscribers__, new_cell_subs)

        :ok
      end
    end
  end

  # ── Module-level helpers (called from injected code above) ───────────────

  @doc false
  def do_fresh_subscribe(mod, sub_info, sub_key, subs, state) do
    ref = Process.monitor(sub_key)
    subscriber = %{sub_info | ref: ref}

    case mod.handle_subscribe(subscriber, state) do
      {:ok, initial_value, new_state} ->
        stored = %{subscriber | last_raw: initial_value}
        Process.put(:__filament_subscribers__, Map.put(subs, sub_key, stored))
        put_session_index(sub_info.session_token, sub_key)
        {:reply, {:ok, initial_value}, new_state}

      {:error, reason, new_state} ->
        Process.demonitor(ref, [:flush])
        {:reply, {:error, reason}, new_state}
    end
  end

  @doc false
  def put_session_index(nil, _sub_key), do: :ok

  def put_session_index(token, sub_key) do
    session_idx = Process.get(:__filament_session_index__, %{})
    Process.put(:__filament_session_index__, Map.put(session_idx, token, sub_key))
  end

  @doc false
  def delete_session_index(nil), do: :ok

  def delete_session_index(token) do
    session_idx = Process.get(:__filament_session_index__, %{})
    Process.put(:__filament_session_index__, Map.delete(session_idx, token))
  end

  @doc false
  def handle_legacy_subscribe(mod, %Filament.Observable.Subscriber{} = sub_info, state) do
    sub_key = sub_info.pid
    subs = Process.get(:__filament_subscribers__, %{})
    session_idx = Process.get(:__filament_session_index__, %{})
    handoff_source = sub_info.session_token && Map.get(session_idx, sub_info.session_token)

    cond do
      is_pid(handoff_source) and handoff_source != sub_key ->
        legacy_subscribe_handoff(mod, sub_info, sub_key, subs, handoff_source, state)

      Map.has_key?(subs, sub_key) ->
        legacy_subscribe_merge(mod, sub_info, sub_key, subs, state)

      true ->
        do_fresh_subscribe(mod, sub_info, sub_key, subs, state)
    end
  end

  defp legacy_subscribe_handoff(mod, sub_info, sub_key, subs, handoff_source, state) do
    case Map.get(subs, handoff_source) do
      nil ->
        do_fresh_subscribe(mod, sub_info, sub_key, subs, state)

      old_sub ->
        Process.demonitor(old_sub.ref, [:flush])
        ref = Process.monitor(sub_key)
        new_sub = %{old_sub | pid: sub_key, ref: ref, proj_keys: sub_info.proj_keys}
        new_subs = subs |> Map.delete(handoff_source) |> Map.put(sub_key, new_sub)
        Process.put(:__filament_subscribers__, new_subs)
        put_session_index(sub_info.session_token, sub_key)
        {:reply, {:ok, old_sub.last_raw}, state}
    end
  end

  defp legacy_subscribe_merge(mod, sub_info, sub_key, subs, state) do
    existing = Map.get(subs, sub_key)
    merged = %{existing | proj_keys: Map.merge(existing.proj_keys, sub_info.proj_keys)}
    Process.put(:__filament_subscribers__, Map.put(subs, sub_key, merged))
    {:ok, initial_value, _} = mod.handle_subscribe(merged, state)
    {:reply, {:ok, initial_value}, state}
  end

  @doc false
  def handle_legacy_remove_projection(mod, sub_key, proj_key, state) do
    subs = Process.get(:__filament_subscribers__, %{})

    case Map.get(subs, sub_key) do
      nil ->
        {:noreply, state}

      subscriber ->
        legacy_remove_projection_for(mod, subscriber, sub_key, subs, proj_key, state)
    end
  end

  defp legacy_remove_projection_for(mod, subscriber, sub_key, subs, proj_key, state) do
    new_proj_keys = Map.delete(subscriber.proj_keys, proj_key)

    if map_size(new_proj_keys) == 0 do
      Process.demonitor(subscriber.ref, [:flush])
      Process.put(:__filament_subscribers__, Map.delete(subs, sub_key))
      delete_session_index(subscriber.session_token)
      {:ok, new_state} = mod.handle_unsubscribe(subscriber, state)
      {:noreply, new_state}
    else
      updated = %{subscriber | proj_keys: new_proj_keys}
      Process.put(:__filament_subscribers__, Map.put(subs, sub_key, updated))
      {:noreply, state}
    end
  end

  @doc false
  def handle_cell_subscribe(mod, subscriber, projection, _from, state) do
    {:ok, raw, new_state} = mod.handle_subscribe(subscriber, state)
    cell_subs = Process.get(:__filament_cell_subscribers__, %{})
    projected = projection.(raw)
    send_pid = subscriber_pid(subscriber)

    entry = %{pid: send_pid, projection: projection, last: projected}
    Process.put(:__filament_cell_subscribers__, Map.put(cell_subs, subscriber, entry))

    {:reply, {:ok, projected}, new_state}
  end

  @doc false
  def handle_cell_current(mod, projection, _from, state) do
    {:ok, raw, new_state} = mod.handle_subscribe(:__filament_current__, state)
    {:reply, projection.(raw), new_state}
  end

  @doc false
  def handle_cell_unsubscribe(subscriber, state) do
    cell_subs = Process.get(:__filament_cell_subscribers__, %{})
    Process.put(:__filament_cell_subscribers__, Map.delete(cell_subs, subscriber))
    {:noreply, state}
  end

  # Locate the sender pid from a subscriber. By convention subscribers are
  # `{pid, ...}` tuples (matching how Filament's hooks layer keys subscribers
  # on owner_pid); anything else falls back to the calling process.
  defp subscriber_pid(sub) when is_tuple(sub) and tuple_size(sub) >= 1 do
    candidate = elem(sub, 0)
    if is_pid(candidate), do: candidate, else: self()
  end

  defp subscriber_pid(_), do: self()

  @doc false
  def notify_cell_each(cell_subs, new_state, max_mailbox_depth) do
    Map.new(cell_subs, fn {sub, %{pid: pid} = entry} ->
      depth_result = Process.info(pid, :message_queue_len)
      {sub, notify_cell_subscriber(sub, entry, new_state, depth_result, max_mailbox_depth)}
    end)
  end

  defp notify_cell_subscriber(sub, entry, new_state, depth_result, max_mailbox_depth) do
    %{pid: pid, projection: proj, last: last} = entry

    if saturated_depth?(depth_result, max_mailbox_depth) do
      log_and_resubscribe_cell(sub, pid, depth_result, max_mailbox_depth)
      entry
    else
      new_projected = proj.(new_state)

      if new_projected !== last do
        send(pid, {:cell_update, sub, new_projected})
        %{entry | last: new_projected}
      else
        entry
      end
    end
  end

  defp log_and_resubscribe_cell(sub, pid, depth_result, max_mailbox_depth) do
    require Logger

    depth_str =
      case depth_result do
        nil -> "dead"
        {:message_queue_len, n} -> "#{n}"
      end

    Logger.warning(
      "[Filament.Observable] cell subscriber #{inspect(pid)} " <>
        "mailbox saturated (depth=#{depth_str}/#{max_mailbox_depth}), " <>
        "dropping update"
    )

    send(pid, {:cell_resubscribe, sub})
  end

  @doc false
  def notify_each(subs, new_state, max_mailbox_depth) do
    Map.new(subs, fn {sub_key, subscriber} ->
      depth_result = Process.info(subscriber.pid, :message_queue_len)
      {sub_key, notify_subscriber(subscriber, new_state, depth_result, max_mailbox_depth)}
    end)
  end

  defp notify_subscriber(subscriber, new_state, depth_result, max_mailbox_depth) do
    cond do
      saturated_depth?(depth_result, max_mailbox_depth) ->
        log_and_resubscribe(subscriber, depth_result, max_mailbox_depth)
        subscriber

      new_state === subscriber.last_raw ->
        subscriber

      true ->
        updates = for {fid, si} <- Map.keys(subscriber.proj_keys), do: {fid, si, new_state}
        send(subscriber.pid, {:filament_observable_updates, updates})
        %{subscriber | last_raw: new_state}
    end
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

    Enum.each(Map.keys(subscriber.proj_keys), fn {fid, si} ->
      send(subscriber.pid, {:filament_observable_resubscribe, fid, si})
    end)

    subscriber
  end
end
