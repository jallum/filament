defmodule Filament.Hooks do
  @moduledoc """
  Hooks for Filament components.

  ## Application-facing hooks

  Call these at the top level of `render/1`:

    - `use_state/1` — local mutable state; returns `{value, setter}`
    - `use_observable/2` — subscribe to an `Observable.GenServer`
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
          {slot_index :: non_neg_integer(), previous_value :: term(), context :: RenderContext.t()}
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
    {index, previous, _ctx} = use_slot(:__unset__)

    if effect_deps_changed?(previous, deps) do
      enqueue_effect(index, effect_fn, deps, previous)
    end

    current_cleanup = extract_cleanup(previous)
    commit_slot(index, {deps, current_cleanup})
    :ok
  end

  defp effect_deps_changed?(:__unset__, _deps), do: true
  defp effect_deps_changed?({_prev_deps, _}, :always), do: true
  defp effect_deps_changed?({prev_deps, _}, deps), do: prev_deps != deps
  defp effect_deps_changed?(_, _), do: true

  defp enqueue_effect(index, effect_fn, deps, previous) do
    old_cleanup = extract_fn_cleanup(previous)
    ctx = Process.get(:filament_render_context)
    effect_entry = {index, ctx.fiber_id, effect_fn, deps, old_cleanup}

    Process.put(
      :filament_render_context,
      %{ctx | pending_effects: [effect_entry | ctx.pending_effects]}
    )
  end

  defp extract_fn_cleanup({_prev_deps, cleanup}) when is_function(cleanup, 0), do: cleanup
  defp extract_fn_cleanup(_), do: nil

  defp extract_cleanup({_prev_deps, cleanup}), do: cleanup
  defp extract_cleanup(_), do: nil

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
    start_fn = build_start_fn(raw_start)

    start_mode = server == nil and start_fn != nil
    request = Keyword.get(opts, :request, nil)
    project = Keyword.get(opts, :project, &Function.identity/1)
    disconnected = Keyword.get(opts, :disconnected, :disconnected)
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    # Skip subscription during disconnected (HTTP static) mounts — subscribing
    # in the HTTP render creates zombie subscribers that inflate presence counts
    # and race with the real WebSocket connection.
    if ctx.subscribe_enabled do
      subscribe_enabled_path(server, start_fn, start_mode, request, project, slot_index, previous, ctx)
    else
      commit_slot(slot_index, :uninitialized)
      if start_mode, do: {nil, disconnected}, else: disconnected
    end
  end

  defp build_start_fn(raw_start) do
    cond do
      is_function(raw_start, 0) -> raw_start
      raw_start != nil -> fn -> raw_start end
      true -> nil
    end
  end

  defp subscribe_enabled_path(server, start_fn, start_mode, request, project, slot_index, previous, ctx) do
    server = resolve_server(server, start_fn, start_mode, previous, ctx)
    value = resolve_value(server, request, project, slot_index, previous, ctx)
    commit_slot(slot_index, {:subscribed, server, value})
    if start_mode, do: {server, value}, else: value
  end

  defp resolve_server(server, _start_fn, _start_mode, _previous, ctx) when server != nil do
    Map.get(ctx.observable_stubs, server, server)
  end

  defp resolve_server(_server, _start_fn, _start_mode, {:subscribed, pid, _}, _ctx) do
    pid
  end

  defp resolve_server(_server, start_fn, true, _previous, _ctx) do
    case start_fn.() do
      {:ok, pid} -> pid
      pid -> pid
    end
  end

  defp resolve_server(_server, _start_fn, _start_mode, _previous, _ctx) do
    raise ArgumentError, "use_observable requires a server or a subscribe: value"
  end

  defp resolve_value(server, request, project, slot_index, previous, ctx) do
    case previous do
      :uninitialized ->
        do_subscribe(server, request, project, ctx, slot_index)

      {:subscribed, ^server, _current} ->
        # Same server — value comes from handle_info updates, just read it.
        read_current_value(ctx, slot_index, server, previous)

      {:subscribed, old_server, _current} ->
        # Server changed — unsubscribe from old, subscribe to new
        maybe_unsubscribe(ctx, old_server, slot_index)
        do_subscribe(server, request, project, ctx, slot_index)

      :needs_resubscribe ->
        do_subscribe(server, request, project, ctx, slot_index)
    end
  end

  defp maybe_unsubscribe(ctx, old_server, slot_index) do
    if is_map_key(ctx.fiber_tree, ctx.fiber_id) do
      Filament.Observable.unsubscribe(old_server, {ctx.owner_pid, ctx.fiber_id, slot_index})
    end
  end

  defp read_current_value(ctx, slot_index, server, previous) do
    case Map.get(ctx.new_hook_slots, slot_index, previous) do
      {:subscribed, ^server, current} -> current
      value -> value
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
          run_memo_factory(slot, deps, factory)
      end
    end
  end

  defp run_memo_factory(slot, deps, factory) do
    ctx = Process.get(:filament_render_context)
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
