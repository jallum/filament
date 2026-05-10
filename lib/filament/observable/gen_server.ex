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
  `{owner_pid, fiber_id, slot_index}` Filament's hooks layer uses). Each
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

  # ── Cell behaviour: GenServer transport ─────────────────────────────────────

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

      # ── Default Observable callbacks (overridable) ───────────────────────

      @impl Filament.Observable
      def handle_subscribe(_subscriber, state), do: {:ok, state, state}

      @impl Filament.Observable
      def handle_unsubscribe(_subscriber, state), do: {:ok, state}

      defoverridable handle_subscribe: 2, handle_unsubscribe: 2

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
      def handle_cast({:filament_cell_unsubscribe, subscriber}, state) do
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
          Filament.Observable.GenServer.notify_cell_each(cell_subs, new_state, @max_mailbox_depth)

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
    ref = if is_pid(send_pid) and send_pid != self(), do: Process.monitor(send_pid)

    entry = %{pid: send_pid, projection: projection, last: projected, monitor_ref: ref}
    Process.put(:__filament_cell_subscribers__, Map.put(cell_subs, subscriber, entry))

    {:reply, {:ok, projected}, new_state}
  end

  @doc false
  def handle_cell_current(mod, projection, _from, state) do
    {:ok, raw, new_state} = mod.handle_subscribe(:__filament_current__, state)
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
        Process.put(:__filament_cell_subscribers__, Map.delete(cell_subs, subscriber))
        {:ok, new_state} = mod.handle_unsubscribe(subscriber, state)
        {:noreply, new_state}
    end
  end

  @doc false
  def handle_cell_down(mod, dead_pid, state) do
    cell_subs = Process.get(:__filament_cell_subscribers__, %{})

    {dead, alive} =
      Enum.split_with(cell_subs, fn {_sub, entry} -> entry.pid == dead_pid end)

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

  @doc false
  def notify_cell_each(cell_subs, new_state, max_mailbox_depth) do
    cell_subs
    |> Enum.flat_map(fn {sub, %{pid: pid} = entry} ->
      depth_result = Process.info(pid, :message_queue_len)

      case notify_cell_subscriber(sub, entry, new_state, depth_result, max_mailbox_depth) do
        :drop -> []
        kept -> [{sub, kept}]
      end
    end)
    |> Map.new()
  end

  defp notify_cell_subscriber(sub, entry, new_state, depth_result, max_mailbox_depth) do
    %{pid: pid, projection: proj, last: last} = entry

    cond do
      is_nil(depth_result) ->
        :drop

      saturated_depth?(depth_result, max_mailbox_depth) ->
        log_and_resubscribe_cell(sub, pid, depth_result, max_mailbox_depth)
        entry

      true ->
        new_projected = proj.(new_state)

        if new_projected === last do
          entry
        else
          send(pid, {:cell_update, sub, new_projected})
          %{entry | last: new_projected}
        end
    end
  end

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
