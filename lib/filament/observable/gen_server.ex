defmodule Filament.Observable.GenServer do
  @moduledoc """
  Macro that makes a GenServer observable to Filament components.

  `use Filament.Observable.GenServer` injects:

    - `handle_call({:filament_cell_subscribe, ...}, from, state)`,
      `handle_call({:filament_cell_current, ...}, from, state)`, and
      `handle_cast({:filament_cell_unsubscribe, ...}, state)` —
      `Filament.Cell` transport callbacks routed to module-level helpers
    - `handle_info({:DOWN, ...}, state)` — removes a dead owner's cells
    - `timeout/1` (overridable) — the GenServer timeout those handlers
      return with; `:infinity` unless the server keeps one of its own
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
    :exit, {:timeout, _} ->
      # The server may still subscribe after the caller gives up; remove it.
      unsubscribe(server, subscriber)
      :disconnected

    :exit, _ ->
      :disconnected
  end

  # A cast, so that unmounting never waits on a busy server. The server
  # handles it before any later request from the same owner.
  @impl Filament.Cell
  def unsubscribe(server, subscriber), do: GenServer.cast(server, {:filament_cell_unsubscribe, subscriber})

  @impl Filament.Cell
  def current(server, projection) when is_function(projection, 1) do
    GenServer.call(server, {:filament_cell_current, projection})
  catch
    :exit, _ -> :disconnected
  end

  @doc """
  `Filament.Cell` callback: the server's pid, or `nil` when it isn't running.
  Names and via-tuples resolve to whichever process is registered now. A pid
  on another node is returned as is; monitoring it reports whether it lives.
  """
  @impl Filament.Cell
  def whereis(server) when is_pid(server) and node(server) != node(), do: server
  def whereis(server) when is_pid(server), do: if(Process.alive?(server), do: server)
  def whereis(server), do: GenServer.whereis(server)

  defmacro __using__(_opts) do
    quote do
      @behaviour Filament.Observable

      use GenServer

      @before_compile Filament.Observable.GenServer

      # ── Default Observable callbacks (overridable) ───────────────────────

      @impl Filament.Observable
      def handle_subscribe(_subscriber, state), do: handle_current(state)

      @impl Filament.Observable
      def handle_unsubscribe(_subscriber, state), do: {:ok, state}

      @impl Filament.Observable
      def handle_current(state), do: {:ok, state, state}

      @impl Filament.Observable
      def timeout(_state), do: :infinity

      defoverridable handle_subscribe: 2, handle_unsubscribe: 2, handle_current: 1, timeout: 1

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
        __MODULE__
        |> Filament.Observable.GenServer.handle_cell_subscribe(subscriber, projection, from, state)
        |> Filament.Observable.GenServer.keep_timeout(__MODULE__)
      end

      @impl true
      def handle_call({:filament_cell_current, projection}, from, state) do
        __MODULE__
        |> Filament.Observable.GenServer.handle_cell_current(projection, from, state)
        |> Filament.Observable.GenServer.keep_timeout(__MODULE__)
      end

      @impl true
      def handle_cast({:filament_cell_unsubscribe, subscriber}, state) do
        __MODULE__
        |> Filament.Observable.GenServer.handle_cell_unsubscribe(subscriber, state)
        |> Filament.Observable.GenServer.keep_timeout(__MODULE__)
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

  # Wraps the module's own handle_info/2, if it has one: the `:DOWN` of a
  # subscriber this server monitors removes its cells, and every other
  # message reaches the module's handler unchanged. Without one, other
  # messages are logged, as GenServer's default handler does.
  @doc false
  defmacro __before_compile__(env) do
    # GenServer's default handler is generated in its own context.
    {:v1, _kind, meta, _clauses} = Module.get_definition(env.module, {:handle_info, 2})
    own_handler? = meta[:context] != GenServer

    fallback =
      if own_handler?,
        do: quote(do: super(message, state)),
        else: quote(do: Filament.Observable.GenServer.unexpected_info(__MODULE__, message, state))

    # A definition here replaces an overridable one only once it is marked
    # overridable again.
    quote do
      defoverridable handle_info: 2

      # The message is matched elsewhere so that the type checker doesn't
      # compare its shape with the module's own clauses.
      @impl true
      def handle_info(message, state) do
        case Filament.Observable.GenServer.handle_cell_info(__MODULE__, message, state) do
          {:handled, reply} -> reply
          :pass -> unquote(fallback)
        end
      end
    end
  end

  @doc false
  def handle_cell_info(mod, {:DOWN, ref, :process, dead_pid, _reason}, state) do
    if cell_monitor?(ref), do: {:handled, mod |> handle_cell_down(dead_pid, state) |> keep_timeout(mod)}, else: :pass
  end

  def handle_cell_info(_mod, _message, _state), do: :pass

  @doc false
  def unexpected_info(mod, message, state) do
    require Logger

    Logger.error("#{inspect(mod)} #{inspect(self())} received unexpected message in handle_info/2: #{inspect(message)}")
    keep_timeout({:noreply, state}, mod)
  end

  # ── Module-level helpers (called from injected code above) ───────────────

  # An injected handler's reply, with the server's own timeout, so that
  # Filament's messages don't cancel it.
  @doc false
  def keep_timeout({:reply, reply, state}, mod), do: {:reply, reply, state, mod.timeout(state)}
  def keep_timeout({:noreply, state}, mod), do: {:noreply, state, mod.timeout(state)}

  @doc false
  # A repeat subscribe with the same identity is a refresh, as after a
  # saturation notice: the domain keeps its subscription, so neither
  # handle_subscribe nor handle_unsubscribe runs, and the reply is the
  # current value under the new projection.
  def handle_cell_subscribe(mod, subscriber, projection, from, state) do
    cell_subs = Process.get(:__filament_cell_subscribers__, %{})

    case Map.fetch(cell_subs, subscriber) do
      {:ok, entry} ->
        {:ok, raw, new_state} = mod.handle_current(state)
        projected = projection.(raw)
        Process.delete(@notification_cache)
        entry = %{entry | projection: projection, last: projected, stale: false}
        Process.put(:__filament_cell_subscribers__, Map.put(cell_subs, subscriber, entry))
        {:reply, {:ok, projected}, new_state}

      :error ->
        case mod.handle_subscribe(subscriber, state) do
          {:ok, raw, new_state} -> add_cell_subscriber(subscriber, projection, from, raw, new_state)
          {:error, _reason, new_state} -> {:reply, :disconnected, new_state}
        end
    end
  end

  defp add_cell_subscriber(subscriber, projection, {caller, _tag}, raw, state) do
    # handle_subscribe may notify observers, so read the map after it.
    cell_subs = Process.get(:__filament_cell_subscribers__, %{})
    projected = projection.(raw)
    pid = subscriber_pid(subscriber, caller)
    ref = if pid != self(), do: Process.monitor(pid)
    entry = %{pid: pid, projection: projection, last: projected, monitor_ref: ref, stale: false}
    new_subs = Map.put(cell_subs, subscriber, entry)
    cache_identity_subscribe(cell_subs, new_subs, entry, raw)
    Process.put(:__filament_cell_subscribers__, new_subs)

    {:reply, {:ok, projected}, state}
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
        {:noreply, state}

      {:ok, entry} ->
        if entry.monitor_ref, do: Process.demonitor(entry.monitor_ref, [:flush])
        Process.delete(@notification_cache)
        Process.put(:__filament_cell_subscribers__, Map.delete(cell_subs, subscriber))
        {:ok, new_state} = mod.handle_unsubscribe(subscriber, state)
        {:noreply, new_state}
    end
  end

  @doc false
  def cell_monitor?(ref) do
    :__filament_cell_subscribers__ |> Process.get(%{}) |> Enum.any?(fn {_sub, entry} -> entry.monitor_ref == ref end)
  end

  @doc false
  def handle_cell_down(mod, dead_pid, state) do
    cell_subs = Process.get(:__filament_cell_subscribers__, %{})

    {dead, alive} =
      Enum.split_with(cell_subs, fn {_sub, entry} -> entry.pid == dead_pid end)

    # One monitor per cell: flush the owner's others so they aren't strays.
    Enum.each(dead, fn {_sub, entry} -> Process.demonitor(entry.monitor_ref, [:flush]) end)

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
  # on owner_pid); any other identity is delivered to the calling process.
  defp subscriber_pid(sub, caller) when is_tuple(sub) and tuple_size(sub) >= 1 do
    candidate = elem(sub, 0)
    if is_pid(candidate), do: candidate, else: caller
  end

  defp subscriber_pid(_sub, caller), do: caller

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
    case mailbox_depth(pid) do
      {:message_queue_len, depth} when depth < max_depth -> true
      _ -> false
    end
  end

  defp notify_and_cache(subscribers, value, max_depth) do
    {updated, owners} = notify_cell_pass(subscribers, value, max_depth)

    if owners && map_size(updated) > 0,
      do: put_notification_cache(updated, value, owners),
      else: Process.delete(@notification_cache)

    updated
  end

  defp notify_cell_pass(cell_subs, new_state, max_mailbox_depth) do
    # Each cell gets one recovery notice, but an owner gets one warning until
    # all its stale cells have resubscribed or been removed.
    stale_owners = MapSet.new(for {_sub, entry} <- cell_subs, Map.get(entry, :stale, false), do: entry.pid)

    {updated_subs, deliveries, depths, identity?, _stale_owners} =
      Enum.reduce(cell_subs, {cell_subs, %{}, %{}, true, stale_owners}, fn {subscriber, entry},
                                                                           {updated, deliveries, depths, identity?,
                                                                            stale_owners} ->
        {depth_result, depths} = owner_depth(entry.pid, depths)
        identity? = identity? and entry.projection === (&Function.identity/1)

        case update_cell_subscriber(subscriber, entry, new_state, depth_result, max_mailbox_depth) do
          :dead ->
            {updated, deliveries, depths, false, stale_owners}

          {_entry, :unchanged} ->
            {updated, deliveries, depths, identity? and current_identity?(entry, new_state), stale_owners}

          {updated_entry, :saturated} ->
            log_saturated_owner_once(stale_owners, entry.pid, depth_result, max_mailbox_depth)

            {Map.put(updated, subscriber, updated_entry), deliveries, depths, false,
             MapSet.put(stale_owners, entry.pid)}

          {updated_entry, {:changed, value}} ->
            next_deliveries =
              Map.update(deliveries, updated_entry.pid, [{subscriber, value}], &[{subscriber, value} | &1])

            {Map.put(updated, subscriber, updated_entry), next_deliveries, depths, identity?, stale_owners}
        end
      end)

    Enum.each(deliveries, fn {pid, updates} -> deliver_cell_updates(pid, Enum.reverse(updates)) end)
    {updated_subs, if(identity?, do: depths)}
  end

  defp current_identity?(entry, value), do: not Map.get(entry, :stale, false) and entry.last === value

  defp log_saturated_owner_once(stale_owners, pid, depth_result, max_depth) do
    if !MapSet.member?(stale_owners, pid), do: log_saturated_cell(pid, depth_result, max_depth)
  end

  # Deliveries are sent after traversal, so all cells owned by a process see
  # the same mailbox snapshot. Avoid querying that process once per cell.
  defp owner_depth(pid, depths) do
    case Map.fetch(depths, pid) do
      {:ok, depth} ->
        {depth, depths}

      :error ->
        depth = mailbox_depth(pid)
        {depth, Map.put(depths, pid, depth)}
    end
  end

  # Another node's mailbox can't be inspected: treat it as empty, and leave
  # the owner's exit to its :DOWN.
  defp mailbox_depth(pid) when node(pid) == node(), do: Process.info(pid, :message_queue_len)
  defp mailbox_depth(_remote_pid), do: {:message_queue_len, 0}

  defp update_cell_subscriber(sub, entry, new_state, depth_result, max_mailbox_depth) do
    %{pid: pid, projection: proj, last: last} = entry

    cond do
      # DOWN cleanup owns removal and handle_unsubscribe; a process that has
      # already exited is not saturated.
      is_nil(depth_result) ->
        :dead

      Map.get(entry, :stale, false) ->
        {entry, :unchanged}

      saturated_depth?(depth_result, max_mailbox_depth) ->
        send(pid, {:cell_resubscribe, sub})
        {Map.put(entry, :stale, true), :saturated}

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

  defp log_saturated_cell(pid, {:message_queue_len, depth}, max_mailbox_depth) do
    require Logger

    Logger.warning(
      "[Filament.Observable] cell subscriber #{inspect(pid)} " <>
        "mailbox saturated (depth=#{depth}/#{max_mailbox_depth}), " <>
        "dropping update"
    )
  end
end
