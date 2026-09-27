defmodule Filament.Observable.GenServer do
  @moduledoc """
  Macro that makes a GenServer observable to Filament components.

  `use Filament.Observable.GenServer` injects:

    - `handle_call({:filament_cell_subscribe, ...}, from, state)`,
      `handle_call({:filament_cell_current, ...}, from, state)`, and
      `handle_cast({:filament_cell_unsubscribe, ...}, state)` —
      `Filament.Cell` transport callbacks routed to module-level helpers
    - `notify_observers/1` — call this from your handlers whenever state
      changes; it walks the cell-subscriber map and pushes updates whose
      projected value has actually changed (change-or-bust)

  Cell subscribers are keyed by an opaque term (typically the tuple
  `{owner_pid, fiber_id, slot_index, generation}` Filament's hooks layer uses). Each
  entry carries the subscriber's projection function so that
  `notify_observers/1` can compute the projected value and compare it
  against the previously delivered one before sending.

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

  @notification_cache :__filament_cell_notification_cache__

  # ── Cell behaviour: GenServer transport ─────────────────────────────────────

  @impl Filament.Cell
  def subscribe(server, subscriber, projection) when is_function(projection, 1) do
    GenServer.call(server, {:filament_cell_subscribe, subscriber, projection})
  catch
    :exit, _ -> :disconnected
  end

  @impl Filament.Cell
  def unsubscribe(server, subscriber) do
    GenServer.call(server, {:filament_cell_unsubscribe, subscriber})
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

  @doc """
  Optional `Filament.Cell` callback. Returns `true` if the underlying
  GenServer is reachable — for raw pids, checks `Process.alive?/1`;
  registered names and via-tuples are always treated as reachable
  (their lookup happens at call time anyway).
  """
  def reachable?(server) when is_pid(server), do: Process.alive?(server)
  def reachable?(server), do: not is_nil(GenServer.whereis(server))

  defmacro __using__(_opts) do
    quote do
      @behaviour Filament.Observable

      use GenServer

      # ── Default Observable callbacks (overridable) ───────────────────────

      @impl Filament.Observable
      def handle_subscribe(_subscriber, state), do: {:ok, state, state}

      @impl Filament.Observable
      def handle_unsubscribe(_subscriber, state), do: {:ok, state}

      @impl Filament.Observable
      def handle_current(state), do: {:ok, state, state}

      defoverridable handle_subscribe: 2, handle_unsubscribe: 2, handle_current: 1

      # ── Cell constructor ────────────────────────────────────────────────

      @doc """
      Build a `%Filament.Source{}` for this server.

      Pass the server reference (pid, registered name, or `{:via, ...}`)
      and get back the struct Filament's hook layer expects. The
      transport module is always `Filament.Observable.GenServer` —
      saves application code from typing it at every call site.

          source = use_source(fn -> __MODULE__.cell(server) end)
          server = source.data

      Override if you want a different default (e.g. ensure-started lookup):

          def cell(session_id) do
            Filament.Source.new(Filament.Observable.GenServer,
                                ensure_started(session_id))
          end
      """
      @spec cell(term()) :: Filament.Source.t()
      def cell(server) do
        Filament.Source.new(Filament.Observable.GenServer, server)
      end

      defoverridable cell: 1

      # ── Injected GenServer message handlers ──────────────────────────────

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
      def handle_call({:filament_cell_unsubscribe, subscriber}, _from, state) do
        Filament.Observable.GenServer.handle_cell_unsubscribe(__MODULE__, subscriber, state)
      end

      @impl true
      def handle_info({:DOWN, _ref, :process, dead_pid, _reason}, state) do
        Filament.Observable.GenServer.handle_cell_down(__MODULE__, dead_pid, state)
      end

      # ── notify_observers/1 ───────────────────────────────────────────────

      @max_mailbox_depth Application.compile_env(:filament, :observable_max_mailbox_depth, 100)

      @doc """
      Notify all subscribers of a new state value.

      For each cell subscriber, applies the subscriber's projection and sends a
      `{:cell_update, subscriber, projected}` message to its pid only when the
      projected value differs from the previously delivered one.

      Call this from your `handle_call`/`handle_cast`/`handle_info` whenever
      state changes and subscribers should re-render.
      """
      @spec notify_observers(new_state :: term()) :: :ok
      def notify_observers(new_state) do
        cell_subs = Process.get(:__filament_cell_subscribers__, %{})

        new_cell_subs =
          Filament.Observable.GenServer.notify_cells(cell_subs, new_state, @max_mailbox_depth)

        Process.put(:__filament_cell_subscribers__, new_cell_subs)

        :ok
      end
    end
  end

  # ── Module-level helpers (called from injected code above) ───────────────

  @doc false
  def handle_cell_subscribe(mod, subscriber, projection, _from, state) do
    {:ok, raw, new_state} = mod.handle_subscribe(subscriber, state)
    cell_subs = Process.get(:__filament_cell_subscribers__, %{})
    projected = projection.(raw)
    send_pid = subscriber_pid(subscriber)
    old_entry = Map.get(cell_subs, subscriber)
    if old_entry && old_entry.monitor_ref, do: Process.demonitor(old_entry.monitor_ref, [:flush])
    ref = if send_pid != self(), do: Process.monitor(send_pid)

    entry = %{pid: send_pid, projection: projection, last: projected, monitor_ref: ref}
    new_subs = Map.put(cell_subs, subscriber, entry)
    cache_identity_subscribe(cell_subs, new_subs, entry, raw)
    Process.put(:__filament_cell_subscribers__, new_subs)

    {:reply, {:ok, projected}, new_state}
  end

  @doc false
  def handle_cell_current(mod, projection, _from, state) do
    {:ok, raw, new_state} = mod.handle_current(state)
    {:reply, projection.(raw), new_state}
  end

  @doc false
  def handle_cell_unsubscribe(mod, subscriber, state) do
    cell_subs = Process.get(:__filament_cell_subscribers__, %{})

    case Map.fetch(cell_subs, subscriber) do
      :error ->
        {:reply, :ok, state}

      {:ok, entry} ->
        if entry.monitor_ref, do: Process.demonitor(entry.monitor_ref, [:flush])
        Process.delete(@notification_cache)
        Process.put(:__filament_cell_subscribers__, Map.delete(cell_subs, subscriber))
        {:ok, new_state} = mod.handle_unsubscribe(subscriber, state)
        {:reply, :ok, new_state}
    end
  end

  @doc false
  def handle_cell_down(mod, dead_pid, state) do
    cell_subs = Process.get(:__filament_cell_subscribers__, %{})

    {dead, alive} =
      Enum.split_with(cell_subs, fn {_sub, entry} -> entry.pid == dead_pid end)

    Process.delete(@notification_cache)
    Process.put(:__filament_cell_subscribers__, Map.new(alive))

    new_state =
      Enum.reduce(dead, state, fn {sub, _entry}, acc ->
        {:ok, next} = mod.handle_unsubscribe(sub, acc)
        next
      end)

    {:noreply, new_state}
  end

  # Locate the sender pid from a subscriber. By convention subscribers are
  # `{pid, ...}` tuples (matching how Filament's hooks layer keys subscribers
  # on owner_pid); anything else falls back to the calling process.
  defp subscriber_pid(sub) when is_tuple(sub) and tuple_size(sub) >= 1 do
    candidate = elem(sub, 0)
    if is_pid(candidate), do: candidate, else: self()
  end

  defp subscriber_pid(_), do: self()

  # Only the known pure identity function may bypass projection evaluation.
  # Keep the exact subscriber map in the cache so subscription replacement
  # cannot reuse a value computed for a previous generation or projection.
  defp cache_identity_subscribe(previous, subscribers, entry, raw) do
    if entry.projection === (&Function.identity/1) do
      case Process.get(@notification_cache) do
        %{subscribers: ^previous, value: ^raw, owners: owners} ->
          put_notification_cache(subscribers, raw, Map.put(owners, entry.pid, true))

        _ when map_size(previous) == 0 ->
          put_notification_cache(subscribers, raw, %{entry.pid => true})

        _ ->
          Process.delete(@notification_cache)
      end
    else
      Process.delete(@notification_cache)
    end
  end

  defp put_notification_cache(subscribers, value, owners) do
    Process.put(@notification_cache, %{subscribers: subscribers, value: value, owners: owners})
  end

  @doc false
  def notify_cells(subscribers, value, max_depth) do
    case Process.get(@notification_cache) do
      %{subscribers: ^subscribers, value: ^value, owners: owners} ->
        if owners_ready?(owners, max_depth),
          do: subscribers,
          else: notify_and_cache(subscribers, value, max_depth)

      _ ->
        notify_and_cache(subscribers, value, max_depth)
    end
  end

  defp owners_ready?(owners, max_depth) do
    Enum.all?(owners, fn {pid, _} -> owner_ready?(pid, max_depth) end)
  end

  defp owner_ready?(pid, max_depth) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, depth} when depth < max_depth -> true
      _ -> false
    end
  end

  defp notify_and_cache(subscribers, value, max_depth) do
    updated = notify_cell_each(subscribers, value, max_depth)

    owners =
      Enum.reduce_while(updated, %{}, fn {_subscriber, entry}, owners ->
        if entry.projection === (&Function.identity/1) and entry.last === value,
          do: {:cont, Map.put(owners, entry.pid, true)},
          else: {:halt, nil}
      end)

    if owners, do: put_notification_cache(updated, value, owners), else: Process.delete(@notification_cache)
    updated
  end

  @doc false
  def notify_cell_each(cell_subs, new_state, max_mailbox_depth) do
    {updated_subs, deliveries, _depths} =
      Enum.reduce(cell_subs, {cell_subs, %{}, %{}}, fn {subscriber, entry}, {updated, deliveries, depths} ->
        {depth_result, depths} = owner_depth(entry.pid, depths)

        case update_cell_subscriber(subscriber, entry, new_state, depth_result, max_mailbox_depth) do
          :drop ->
            {Map.delete(updated, subscriber), deliveries, depths}

          {_entry, :unchanged} ->
            {updated, deliveries, depths}

          {updated_entry, {:changed, value}} ->
            next_deliveries =
              Map.update(deliveries, updated_entry.pid, [{subscriber, value}], &[{subscriber, value} | &1])

            {Map.put(updated, subscriber, updated_entry), next_deliveries, depths}
        end
      end)

    Enum.each(deliveries, fn {pid, updates} -> deliver_cell_updates(pid, Enum.reverse(updates)) end)
    updated_subs
  end

  # Deliveries are sent after traversal, so all cells owned by a process see
  # the same mailbox snapshot. Avoid querying that process once per cell.
  defp owner_depth(pid, depths) do
    case Map.fetch(depths, pid) do
      {:ok, depth} ->
        {depth, depths}

      :error ->
        depth = Process.info(pid, :message_queue_len)
        {depth, Map.put(depths, pid, depth)}
    end
  end

  defp update_cell_subscriber(sub, entry, new_state, depth_result, max_mailbox_depth) do
    %{pid: pid, projection: proj, last: last} = entry

    cond do
      is_nil(depth_result) ->
        :drop

      saturated_depth?(depth_result, max_mailbox_depth) ->
        log_and_resubscribe_cell(sub, pid, depth_result, max_mailbox_depth)
        {entry, :unchanged}

      true ->
        new_projected = proj.(new_state)

        if new_projected === last do
          {entry, :unchanged}
        else
          {%{entry | last: new_projected}, {:changed, new_projected}}
        end
    end
  end

  defp deliver_cell_updates(pid, [{subscriber, value}]), do: send(pid, {:cell_update, subscriber, value})
  defp deliver_cell_updates(pid, updates), do: send(pid, {:cell_updates, updates})

  defp saturated_depth?({:message_queue_len, n}, max) when n >= max, do: true
  defp saturated_depth?(_, _), do: false

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
end
