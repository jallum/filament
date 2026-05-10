defmodule Filament.Hooks do
  @moduledoc """
  Hooks for Filament components.

  ## Application-facing hooks

  Call these at the top level of `render/1`:

    - `use_state/1` — local mutable state; returns `{value, setter}`
    - `use_observable/1` — resolves a server reference to a pid (or nil when disconnected)
    - `use_observable/2` — resolves a server and projects its state; fn receives `:disconnected` when unavailable
    - `use_effect/2` — side-effect with optional cleanup
    - `memo_at/3` and `event_at/2` — invoked by compiler-generated code from `~F` templates

  ## Pattern: use_observable/1 + use_observable/2

  Resolve the server once with `/1`, then project from it with `/2`. This lets you pass
  the server pid to child components and apply multiple projections from the same process:

      def render(%{session_id: session_id}) do
        server = use_observable(fn -> MyServer.start_link(session_id) end)
        count  = use_observable(server, fn
          :disconnected -> 0
          state -> state.count
        end)
        label  = use_observable(server, fn
          :disconnected -> ""
          state -> state.label
        end)
        ...
      end

  Passing the server as a prop lets child components project their own values without
  creating redundant subscriptions:

      <ChildComponent server={server} />

      # In the child:
      def render(%{server: server}) do
        value = use_observable(server, fn
          :disconnected -> nil
          s -> s.some_field
        end)
        ...
      end

  ## Rules of hooks

  1. Only call hooks at the top level of `render/1` — not inside `if`, `case`, or comprehensions.
  2. Hooks must be called during a render pass (a `RenderContext` must be active).
  3. Hook identity is determined by call order (slot index). Conditional hooks corrupt state.
  """

  alias Filament.Observable.Subscriber
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
  Resolves an observable server reference to a pid, without subscribing.

  The argument can be any of:
  - a pid, atom, `{:via, ...}`, or `{node, name}` — used directly as the server
  - a zero-arity function — called on first connect (and again if the process dies) to
    obtain a pid or `{:ok, pid}`; useful when the component owns the server's lifecycle

  Returns `nil` during disconnected (HTTP static) mounts. On subsequent renders,
  reuses an existing pid if still alive; restarts a factory fn otherwise.

  Use this hook when you want to pass the server identity to child components or
  apply multiple projections from the same server via `use_observable/2`.

  Must be called at the top level of `render/1` in consistent order (like all hooks).
  """
  @spec use_observable(
          server_or_fn ::
            GenServer.server()
            | (-> pid() | {:ok, pid()} | GenServer.server())
        ) :: pid() | GenServer.server() | nil
  def use_observable(server_or_fn) do
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    if ctx.subscribe_enabled do
      server = resolve_server(server_or_fn, previous, ctx)
      commit_slot(slot_index, {:resolved, server})
      server
    else
      commit_slot(slot_index, :uninitialized)
      nil
    end
  end

  @doc """
  Resolve an observable server and project its state into a value.

  The first argument is a server reference (same as `use_observable/1`). The second
  argument is a projection function called on every state update from the server. When
  the server is unavailable (disconnected HTTP mount or nil), the function is called
  with the atom `:disconnected` so it can return a safe default:

      count = use_observable(CartServer, fn
        :disconnected -> 0
        state        -> state.count
      end)

  Passing the server as a prop lets a parent resolve the process once and share it with
  children that each apply their own projection:

      # Parent
      server = use_observable(fn -> MyServer.start_link([]) end)
      <Child server={server} />

      # Child
      value = use_observable(server, fn
        :disconnected -> nil
        s             -> s.some_field
      end)

  Must be called at the top level of `render/1` in consistent order (like all hooks).
  Do not call inside conditionals or loops.
  """
  @spec use_observable(
          server_or_fn ::
            GenServer.server()
            | (-> pid() | {:ok, pid()} | GenServer.server()),
          project :: (term() | :disconnected -> term())
        ) :: term()
  def use_observable(server_or_fn, project) when is_function(project, 1) do
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    if ctx.subscribe_enabled do
      server = resolve_server(server_or_fn, previous, ctx)
      {value, raw} = resolve_value(server, project, slot_index, previous, ctx)
      commit_slot(slot_index, {:subscribed, server, raw})
      value
    else
      commit_slot(slot_index, :uninitialized)
      project.(:disconnected)
    end
  end

  defp resolve_server(factory_fn, previous, _ctx) when is_function(factory_fn, 0) do
    case previous do
      {:subscribed, pid, _raw} when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: call_factory(factory_fn)

      {:resolved, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: call_factory(factory_fn)

      _ ->
        call_factory(factory_fn)
    end
  end

  defp resolve_server(server, _previous, ctx) do
    Map.get(ctx.observable_stubs, server, server)
  end

  defp call_factory(factory_fn) do
    case factory_fn.() do
      {:ok, pid} -> pid
      pid -> pid
    end
  end

  defp resolve_value(server, project, slot_index, previous, ctx) do
    case previous do
      :uninitialized ->
        do_subscribe(server, project, ctx, slot_index)

      {:subscribed, ^server, prev_raw} ->
        # Same server — re-apply project with current closure.
        # Prefer fresher raw state from new_hook_slots (server update since last render).
        raw =
          case Map.get(ctx.new_hook_slots, slot_index) do
            {:subscribed, _, new_raw} -> new_raw
            _ -> prev_raw
          end

        {project.(raw), raw}

      {:subscribed, old_server, _prev_raw} ->
        # Server changed — remove our projection from old server, subscribe to new.
        maybe_remove_projection(ctx, old_server, slot_index)
        do_subscribe(server, project, ctx, slot_index)

      :needs_resubscribe ->
        do_subscribe(server, project, ctx, slot_index)
    end
  end

  defp maybe_remove_projection(ctx, old_server, slot_index) do
    if is_map_key(ctx.fiber_tree, ctx.fiber_id) do
      Filament.Observable.remove_projection(
        old_server,
        ctx.owner_pid,
        ctx.fiber_id,
        slot_index
      )
    end
  end

  @doc """
  Subscribe the current fiber to a `Filament.Cell` and apply a projection.

  Generic over the cell's transport — works against any module that implements
  `Filament.Cell` (the GenServer-backed observable, an in-process struct, a
  focus tracker, etc.). The component is unaware of how the cell is fed.

  The hook subscribes with identity projection (the cell delivers raw values)
  and applies the user-supplied `projection` at render time. This matches
  `use_observable/2`'s closure-freshness semantics: a projection that closes
  over local component state always sees the current value.

  Returns `projection.(:disconnected)` during static (HTTP) renders and when
  the cell can't reach its source.

  ## Example

      defmodule Counter do
        use Filament.Observable.GenServer
        # ... handlers omitted ...
      end

      def render(%{counter: counter}) do
        cell = {Filament.Observable.GenServer, counter}

        count =
          use_cell(cell, fn
            :disconnected -> 0
            n -> n
          end)

        ~F"<p>{count}</p>"
      end

  Must be called at the top level of `render/1` in consistent order.
  """
  @spec use_cell(Filament.Cell.t(), (term() | :disconnected -> term())) :: term()
  def use_cell(cell, projection) when is_function(projection, 1) do
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    if ctx.subscribe_enabled do
      use_cell_subscribed(cell, projection, slot_index, previous, ctx)
    else
      commit_slot(slot_index, :uninitialized)
      projection.(:disconnected)
    end
  end

  defp use_cell_subscribed(cell, projection, slot_index, previous, ctx) do
    case resolve_cell_value(cell, slot_index, previous, ctx) do
      :disconnected ->
        commit_slot(slot_index, :uninitialized)
        projection.(:disconnected)

      raw ->
        commit_slot(slot_index, {:cell_subscribed, raw})
        projection.(raw)
    end
  end

  # Read the cell's raw value: prefer the fresher value from `new_hook_slots`
  # (set by an in-flight `:cell_update`), fall back to the previously cached
  # value, or subscribe fresh on first render.
  defp resolve_cell_value(cell, slot_index, previous, ctx) do
    case Map.get(ctx.new_hook_slots, slot_index) do
      {:cell_subscribed, raw} ->
        raw

      _ ->
        case previous do
          {:cell_subscribed, raw} ->
            raw

          _ ->
            cell_subscribe_fresh(cell, slot_index, ctx)
        end
    end
  end

  defp cell_subscribe_fresh(cell, slot_index, ctx) do
    subscriber = {ctx.owner_pid, ctx.fiber_id, slot_index}

    case Filament.Cell.subscribe(cell, subscriber, &Function.identity/1) do
      {:ok, value} -> value
      :disconnected -> :disconnected
    end
  end

  defp do_subscribe(server, project, ctx, slot_index) do
    subscriber = %Subscriber{
      pid: ctx.owner_pid,
      proj_keys: %{{ctx.fiber_id, slot_index} => true},
      session_token: ctx.session_token
    }

    case Filament.Observable.subscribe(server, subscriber) do
      {:ok, initial_raw} ->
        {project.(initial_raw), initial_raw}

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
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError, "hook called outside a render pass — hooks may only be called from render/1"

    fiber_id_str = to_string(ctx.fiber_id)
    new_handlers = Map.put(ctx.new_event_handlers, slot, handler)
    Process.put(:filament_render_context, %{ctx | new_event_handlers: new_handlers})
    "#{fiber_id_str}:#{slot}"
  end

  @doc false
  def set_event_handler_floor(n) when is_integer(n) do
    case Process.get(:filament_render_context) do
      nil -> :ok
      ctx when ctx.event_handler_index < n ->
        Process.put(:filament_render_context, %{ctx | event_handler_index: n})
      _ -> :ok
    end
  end

  @doc false
  @spec register_event_handler(handler :: function()) :: wire_ref :: String.t()
  def register_event_handler(handler) when is_function(handler) do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError, "hook called outside a render pass — hooks may only be called from render/1"

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
