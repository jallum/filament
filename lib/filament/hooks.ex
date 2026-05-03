defmodule Filament.Hooks do
  @moduledoc """
  Hooks for Filament components.

  ## Application-facing hooks

  Call these at the top level of `render/1`:

    - `use_state/1` — local mutable state; returns `{value, setter}`
    - `use_observable/2` — subscribe to an `Observable.GenServer`
    - `use_hold/3` — subscribe to a `Hold.GenServer`; returns `{held_qty, item, hold, release}`
    - `use_effect/2` — side-effect with optional cleanup
    - `memo_at/3` and `event_at/2` — invoked by compiler-generated code from `~F` templates

  ## Rules of hooks

  1. Only call hooks at the top level of `render/1` — not inside `if`, `case`, or comprehensions.
  2. Hooks must be called during a render pass (a `RenderContext` must be active).
  3. Hook identity is determined by call order (slot index). Conditional hooks corrupt state.
  """

  alias Filament.RenderContext

  @doc false
  @spec use_slot(default :: term()) ::
          {slot_index :: non_neg_integer(), previous_value :: term(),
           context :: RenderContext.t()}
  def use_slot(default) do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError,
              "hook called outside a render pass — hooks may only be called from render/1"

    index = ctx.hook_index

    # Look up previous value: first from ctx.hook_slots (for new child fibers),
    # then from fiber_tree for existing fibers being re-rendered
    previous =
      case Map.get(ctx.hook_slots, index) do
        nil ->
          fiber = Map.get(ctx.fiber_tree, ctx.fiber_id)
          if fiber, do: Map.get(fiber.hook_slots, index, default), else: default

        value ->
          value
      end

    Process.put(:filament_render_context, %{ctx | hook_index: index + 1})
    {index, previous, ctx}
  end

  @doc false
  @spec commit_slot(slot_index :: non_neg_integer(), value :: term()) :: :ok
  def commit_slot(index, value) do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError, "commit_slot called outside a render pass"

    updated = Map.put(ctx.new_hook_slots, index, value)
    Process.put(:filament_render_context, %{ctx | new_hook_slots: updated})
    :ok
  end

  @doc false
  @spec current_context() :: RenderContext.t() | nil
  def current_context, do: Process.get(:filament_render_context)

  @doc """
  Returns the current state value and a setter function.

  On the first render of this fiber, returns {initial, setter}.
  On subsequent renders, returns the most recently set value (or initial if never changed).

  The setter is a closure. Call it from event handlers or effects to trigger a re-render.
  Calling the setter sends a message to the owning LiveView process, which re-renders
  the affected fiber.

  Rules: call only at the top level of render/1. Do not call inside conditionals.
  """
  @spec use_state(initial :: term()) :: {value :: term(), setter :: (term() -> :ok)}
  def use_state(initial) do
    {index, previous, ctx} = use_slot({initial, :__no_setter__})

    {value, setter} =
      case previous do
        {val, s} when is_function(s, 1) ->
          # Reuse stable setter from previous render
          {val, s}

        _ ->
          # First render or no setter stored — build a new one
          {initial, build_setter(ctx.fiber_id, index, ctx.owner_pid)}
      end

    commit_slot(index, {value, setter})
    {value, setter}
  end

  defp build_setter(fiber_id, slot_index, owner_pid) when is_pid(owner_pid) do
    fn new_value ->
      send(owner_pid, {:filament_set_state, fiber_id, slot_index, new_value})
      :ok
    end
  end

  defp build_setter(_fiber_id, _slot_index, nil) do
    fn _new_value -> :ok end
  end

  @doc """
  Schedules a side effect to run after the render completes.

  effect_fn is called after the component renders. It may return a cleanup function
  (zero-arity fn returning :ok or any term) that is called:
  - Before the next time the effect runs (when deps change), OR
  - When the fiber unmounts

  deps controls when the effect re-runs:
  - [] — run once on mount, cleanup on unmount
  - [dep1, dep2] — run when any dep changes (Kernel.== comparison), cleanup before re-run
  - :always — run on every render

  Rules: call only at the top level of render/1.
  """
  @spec use_effect((-> (-> term()) | nil), deps :: [term()] | :always) :: :ok
  def use_effect(effect_fn, deps) when is_function(effect_fn, 0) do
    {index, previous, ctx} = use_slot(:__unset__)

    deps_changed? =
      case previous do
        :__unset__ -> true
        {_prev_deps, _} when deps == :always -> true
        {prev_deps, _} -> prev_deps != deps
        _ -> true
      end

    if deps_changed? do
      old_cleanup =
        case previous do
          {_prev_deps, cleanup} when is_function(cleanup, 0) -> cleanup
          _ -> nil
        end

      effect_entry = {index, ctx.fiber_id, effect_fn, deps, old_cleanup}
      ctx = Process.get(:filament_render_context)

      Process.put(
        :filament_render_context,
        %{ctx | pending_effects: [effect_entry | ctx.pending_effects]}
      )
    end

    current_cleanup =
      case previous do
        {_prev_deps, cleanup} -> cleanup
        _ -> nil
      end

    commit_slot(index, {deps, current_cleanup})
    :ok
  end

  @doc """
  Subscribe this fiber to `server`, returning the current projected value.

  ## Server form

      use_observable(server, opts \\ [])

  Returns the current projected value. Options:
  - `:request`      — passed to `handle_subscribe/3` (default `nil`)
  - `:project`      — `(state -> term())` projection applied to each update (default identity)
  - `:disconnected` — value returned before the WebSocket connects (default `:disconnected`)

  ## Subscribe form

      use_observable(subscribe: fn -> ... end, opts)

  When the server should be started by the component itself, omit the `server` argument
  and supply a `:subscribe` option instead. Returns `{pid, value}` so the pid is available
  for mutations. When disconnected returns `{nil, disconnected_value}`.
  - `:subscribe`    — zero-arity fn called once on the first WebSocket render (must return a pid or `{:ok, pid}`),
                    or any GenServer name (pid, atom, `{:via, ...}`) used directly as the server
  - `:disconnected` — the *value* half of the `{nil, value}` tuple returned while disconnected

  Must be called at the top level of a component's `render/1`, in consistent order
  across renders (like all hooks). Do not call inside conditionals or loops.

  ## Examples

      counter = use_observable(CounterServer, project: fn s -> s.count end)

      {store, todos} = use_observable(subscribe: fn -> Todo.Store.start_link!([]) end, disconnected: [])
  """
  @spec use_observable(
          server :: GenServer.server(),
          opts :: [request: term(), project: (term() -> term()), disconnected: term()]
        ) :: term()
  @spec use_observable(
          opts :: [
            subscribe: (-> pid()),
            request: term(),
            project: (term() -> term()),
            disconnected: term()
          ]
        ) :: {pid() | nil, term()}
  def use_observable(server_or_opts, opts \\ [])

  def use_observable(opts, []) when is_list(opts) do
    do_use_observable(nil, opts)
  end

  def use_observable(server, opts) do
    do_use_observable(server, opts)
  end

  defp do_use_observable(server, opts) do
    raw_start = Keyword.get(opts, :subscribe, nil)
    # Allow subscribe: to be a 0-arity fn (starts a process) or any GenServer name
    # (pid, atom, {:via, ...}) — wrap the latter so the rest of the path is uniform.
    start_fn =
      cond do
        is_function(raw_start, 0) -> raw_start
        raw_start != nil -> fn -> raw_start end
        true -> nil
      end
    start_mode = server == nil and start_fn != nil
    request = Keyword.get(opts, :request, nil)
    project = Keyword.get(opts, :project, &Function.identity/1)
    disconnected = Keyword.get(opts, :disconnected, :disconnected)
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    # Skip subscription during disconnected (HTTP static) mounts — subscribing
    # in the HTTP render creates zombie subscribers that inflate presence counts
    # and race with the real WebSocket connection.
    if not ctx.subscribe_enabled do
      commit_slot(slot_index, :uninitialized)
      if start_mode, do: {nil, disconnected}, else: disconnected
    else
      # Resolve the server pid: explicit arg > reuse from slot > call subscribe:
      server =
        cond do
          server != nil ->
            Map.get(ctx.observable_stubs, server, server)

          match?({:subscribed, _pid, _}, previous) ->
            {:subscribed, pid, _} = previous
            pid

          start_mode ->
            case start_fn.() do
              {:ok, pid} -> pid
              pid -> pid
            end

          true ->
            raise ArgumentError, "use_observable requires a server or a subscribe: value"
        end

      value =
        case previous do
          :uninitialized ->
            do_subscribe(server, request, project, ctx, slot_index)

          {:subscribed, ^server, _current} ->
            # Same server — value comes from handle_info updates, just read it.
            # The current value was stored by handle_info during the last update.
            Map.get(ctx.new_hook_slots, slot_index, previous)
            |> case do
              {:subscribed, ^server, current} -> current
              value -> value
            end

          {:subscribed, old_server, _current} ->
            # Server changed — unsubscribe from old, subscribe to new
            if is_map_key(ctx.fiber_tree, ctx.fiber_id) do
              Filament.Observable.unsubscribe(
                old_server,
                {ctx.owner_pid, ctx.fiber_id, slot_index}
              )
            end

            do_subscribe(server, request, project, ctx, slot_index)

          :needs_resubscribe ->
            do_subscribe(server, request, project, ctx, slot_index)
        end

      commit_slot(slot_index, {:subscribed, server, value})
      if start_mode, do: {server, value}, else: value
    end
  end

  defp do_subscribe(server, request, project, ctx, slot_index) do
    subscriber = %Filament.Observable.Subscriber{
      pid: ctx.owner_pid,
      fiber_id: ctx.fiber_id,
      slot_index: slot_index,
      project: project
    }

    case Filament.Observable.subscribe(server, request, subscriber) do
      {:ok, initial_value} ->
        # Apply projection to initial value so hooks always see the projected shape,
        # consistent with subsequent update messages from notify_observers.
        project.(initial_value)

      {:error, reason} ->
        raise Filament.ObservableError,
          message: "use_observable subscription rejected: #{inspect(reason)}",
          observable: server,
          reason: reason
    end
  end

  @doc """
  Subscribe to a `Hold.GenServer` and manage quantity-based resource holds.

  Returns `{held_qty, item, hold, release}` on a live WebSocket connection:

  - `held_qty` — number of units this component currently holds
  - `item` — the current observable value for `item_id` from the server
  - `hold.(qty)` — acquire `qty` more units; raises `HoldError` if denied
  - `release.(qty)` — release up to `qty` units

  Returns `:disconnected` (or the value of `disconnected:`) during the HTTP
  pre-render before the WebSocket connects.

  Holds are released automatically when the LiveView disconnects.

  Options:
  - `project:` — fn/1 applied to server state to extract `item`; defaults to
    `fn state -> state[item_id] end`, suitable for map-keyed stores.
  - `disconnected:` — value returned before WebSocket connects (default `:disconnected`)
  """
  @spec use_hold(server :: GenServer.server(), item_id :: term(), opts :: keyword()) ::
          {held_qty :: non_neg_integer(), item :: term(),
           hold :: (pos_integer() -> :ok), release :: (pos_integer() -> :ok)}
          | term()
  def use_hold(server, item_id, opts \\ []) do
    disconnected_val = Keyword.get(opts, :disconnected, :disconnected)
    project = Keyword.get(opts, :project, &Map.get(&1, item_id))
    sentinel = :__hold_disconnected__

    item = use_observable(server, request: item_id, project: project, disconnected: sentinel)
    {held_qty, set_held_qty} = use_state(0)

    if item == sentinel do
      disconnected_val
    else
      owner_pid = current_context().owner_pid

      hold_fn = fn qty ->
        case GenServer.call(server, {:filament_hold, item_id, qty, owner_pid}) do
          :ok ->
            set_held_qty.(held_qty + qty)

          {:error, reason} ->
            raise Filament.HoldError,
              message: "use_hold acquisition rejected by #{inspect(server)}: #{inspect(reason)}",
              server: server,
              reason: reason
        end
      end

      # release always fires the cast; server caps at actual held qty
      release_fn = fn qty ->
        GenServer.cast(server, {:filament_release_qty, item_id, qty, owner_pid})
        set_held_qty.(max(0, held_qty - qty))
      end

      {held_qty, item, hold_fn, release_fn}
    end
  end

  @doc false
  @spec memo_at(
          slot :: non_neg_integer() | {:t, non_neg_integer()},
          deps :: [term()] | :no_deps,
          factory :: (-> term())
        ) :: term()
  def memo_at(slot, deps, factory) when is_function(factory, 0) do
    ctx = Process.get(:filament_render_context)

    if is_nil(ctx) do
      # Called outside a render pass (PLV diff engine re-evaluating comprehension entry fns).
      # Just compute and return — no caching needed here.
      factory.()
    else
      previous = read_slot_at(ctx, slot)

      case previous do
        {:memo, cached_deps, cached_value, handler_range}
        when deps != :no_deps and cached_deps == deps ->
          # Cache hit: replay event handlers registered by the factory last time
          # so the fiber's event_handlers map stays populated without re-running factory.
          replay_handler_range(ctx, handler_range)
          after_ctx = Process.get(:filament_render_context)
          slot_entry = {:memo, cached_deps, cached_value, handler_range}
          updated = Map.put(after_ctx.new_hook_slots, slot, slot_entry)
          Process.put(:filament_render_context, %{after_ctx | new_hook_slots: updated})
          cached_value

        _ ->
          # Cache miss or first render: run factory, record which handler indices it used.
          e_start = ctx.event_handler_index
          value = factory.()
          after_ctx = Process.get(:filament_render_context)
          e_end = after_ctx.event_handler_index
          stored_deps = if deps == :no_deps, do: :no_deps, else: deps
          slot_entry = {:memo, stored_deps, value, {e_start, e_end}}
          updated = Map.put(after_ctx.new_hook_slots, slot, slot_entry)
          Process.put(:filament_render_context, %{after_ctx | new_hook_slots: updated})
          value
      end
    end
  end

  defp read_slot_at(ctx, slot) do
    case Map.get(ctx.hook_slots, slot) do
      nil ->
        fiber = Map.get(ctx.fiber_tree, ctx.fiber_id)
        if fiber, do: Map.get(fiber.hook_slots, slot, :__unset__), else: :__unset__

      value ->
        value
    end
  end

  # Replay event handlers from the previous fiber for the given auto-increment index range.
  defp replay_handler_range(_ctx, {e_start, e_start}), do: :ok

  defp replay_handler_range(ctx, {e_start, e_end}) do
    fiber = Map.get(ctx.fiber_tree, ctx.fiber_id)

    if fiber do
      after_ctx = Process.get(:filament_render_context)
      replayed = Map.take(fiber.event_handlers, Enum.to_list(e_start..(e_end - 1)))
      merged = Map.merge(after_ctx.new_event_handlers, replayed)
      Process.put(:filament_render_context, %{after_ctx | new_event_handlers: merged})
    end
  end

  @doc false
  @spec event_at(slot :: non_neg_integer(), handler :: function()) :: wire_ref :: String.t()
  def event_at(slot, handler) when is_function(handler) do
    case Process.get(:filament_render_context) do
      nil ->
        # Called outside a render pass (PLV diff engine re-evaluating comprehension entry fns).
        # Handlers were already committed during the render pass; return a stable ref.
        {fiber_id, _} = Process.get(:filament_diff_eval_state, {"unknown", 0})
        "#{fiber_id}:#{slot}"

      ctx ->
        fiber_id_str = to_string(ctx.fiber_id)
        new_handlers = Map.put(ctx.new_event_handlers, slot, handler)
        Process.put(:filament_render_context, %{ctx | new_event_handlers: new_handlers})
        "#{fiber_id_str}:#{slot}"
    end
  end

  @doc false
  @spec register_event_handler(handler :: function()) :: wire_ref :: String.t()
  def register_event_handler(handler) when is_function(handler) do
    case Process.get(:filament_render_context) do
      nil ->
        {fiber_id, idx} = Process.get(:filament_diff_eval_state, {"unknown", 0})
        Process.put(:filament_diff_eval_state, {fiber_id, idx + 1})
        "#{fiber_id}:#{idx}"

      ctx ->
        idx = ctx.event_handler_index
        fiber_id_str = to_string(ctx.fiber_id)

        new_ctx = %{
          ctx
          | event_handler_index: idx + 1,
            new_event_handlers: Map.put(ctx.new_event_handlers, idx, handler)
        }

        Process.put(:filament_render_context, new_ctx)
        "#{fiber_id_str}:#{idx}"
    end
  end
end
