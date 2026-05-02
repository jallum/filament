defmodule Filament.Hooks do
  @moduledoc """
  Low-level hook slot primitives. Not called by application code directly.
  Application code uses use_state/1, use_memo/2, use_effect/2.

  Rules of hooks:
  1. Only call hooks at the top level of render/1.
  2. Only call hooks during a render pass.
  3. Hooks are identified by call order (slot index). Conditional hooks corrupt state.
  """

  alias Filament.RenderContext

  @doc """
  Acquires the next hook slot. Returns {slot_index, previous_value, context} where:
  - slot_index is the current index (0-based, increments with each call)
  - previous_value is the value stored in this slot from the PREVIOUS render
    (or the given default if this is the first render or the slot is empty)
  - context is the current RenderContext (for use by the calling hook)

  Raises if called outside a render pass (no context in process dictionary).
  """
  @spec use_slot(default :: term()) ::
          {slot_index :: non_neg_integer(), previous_value :: term(),
           context :: RenderContext.t()}
  def use_slot(default) do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError,
              "hook called outside a render pass — hooks may only be called from render/1"

    index = ctx.hook_index
    fiber = Map.get(ctx.fiber_tree, ctx.fiber_id)
    previous = if fiber, do: Map.get(fiber.hook_slots, index, default), else: default

    Process.put(:filament_render_context, %{ctx | hook_index: index + 1})
    {index, previous, ctx}
  end

  @doc """
  Writes a new value for the given slot index into the render context accumulator.
  The value is committed to the fiber after the render pass completes.
  """
  @spec commit_slot(slot_index :: non_neg_integer(), value :: term()) :: :ok
  def commit_slot(index, value) do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError, "commit_slot called outside a render pass"

    updated = Map.put(ctx.new_hook_slots, index, value)
    Process.put(:filament_render_context, %{ctx | new_hook_slots: updated})
    :ok
  end

  @doc """
  Returns the current render context, or nil if called outside a render pass.
  Used by hooks that need owner_pid (C2) or to schedule effects (C4).
  """
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
  Returns a memoized value recomputed only when deps changes.

  On the first render, always calls fun.() and caches the result.
  On subsequent renders, compares deps to the previously stored deps using structural
  equality. If deps is equal, returns the cached value. If deps changed, calls fun.()
  and caches the new result.

  Pass `[]` as deps to compute only once (on mount).
  Pass `:no_deps` to recompute every render.

  Rules: call only at the top level of render/1.
  """
  @spec use_memo((-> result), deps :: [term()] | :no_deps) :: result when result: term()
  def use_memo(fun, deps) when is_function(fun, 0) do
    {index, previous, _ctx} = use_slot(:__unset__)

    {value, stored_deps} =
      case previous do
        :__unset__ ->
          # First render
          {fun.(), deps}

        {cached_deps, cached_value} ->
          if deps == :no_deps or cached_deps != deps do
            {fun.(), deps}
          else
            {cached_value, cached_deps}
          end

        _other ->
          # Unexpected slot content — recompute
          {fun.(), deps}
      end

    commit_slot(index, {stored_deps, value})
    value
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

  - `server`  — PID or registered name of the observable GenServer
  - `request` — passed to `handle_subscribe/3` (default `nil`)
  - `opts`    — keyword list:
      `:project` — `(state :: term() -> term())` projection function (default identity)

  Must be called at the top level of a component's `render/1`, in consistent order
  across renders (like all hooks). Do not call inside conditionals or loops.

  ## Examples

      counter = use_observable(CounterServer, nil, project: fn s -> s.count end)
  """
  @spec use_observable(
          server :: GenServer.server(),
          request :: term(),
          opts :: [project: (term() -> term())]
        ) :: term()
  def use_observable(server, request \\ nil, opts \\ []) do
    project = Keyword.get(opts, :project, &Function.identity/1)
    {slot_index, previous, ctx} = use_slot(:uninitialized)
    server = Map.get(ctx.observable_stubs, server, server)

    # Skip subscription during disconnected (HTTP static) mounts — subscribing
    # in the HTTP render creates zombie subscribers that inflate presence counts
    # and race with the real WebSocket connection.
    if not ctx.subscribe_enabled do
      commit_slot(slot_index, :uninitialized)
      :uninitialized
    else
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
      value
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
  Acquire a resource hold on `server` on behalf of this fiber's LiveView process.
  Released automatically when the LiveView disconnects (:DOWN) or the fiber unmounts.

  - `server`  — PID or registered name of a `Filament.Hold.GenServer`
  - `request` — passed to `handle_acquire/3` on the server (default `nil`)
  - `opts`    — reserved for future use (default `[]`)

  Returns the opaque token from `handle_acquire/3`.
  Raises `Filament.HoldError` if the server rejects the request.
  """
  @spec use_hold(server :: GenServer.server(), request :: term(), opts :: keyword()) ::
          token :: term()
  def use_hold(server, request \\ nil, opts \\ []) do
    _ = opts
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    token =
      case previous do
        :uninitialized ->
          do_acquire(server, request, ctx.owner_pid)

        {:held, ^server, current_token} ->
          current_token

        {:held, old_server, _current_token} ->
          # Server changed between renders — release old hold, acquire new one
          if is_map_key(ctx.fiber_tree, ctx.fiber_id) do
            parent_pid = ctx.owner_pid || self()
            Filament.Hold.release(old_server, parent_pid)
          end

          do_acquire(server, request, ctx.owner_pid)

        :needs_reacquire ->
          do_acquire(server, request, ctx.owner_pid)
      end

    commit_slot(slot_index, {:held, server, token})
    token
  end

  defp do_acquire(server, request, holder_pid) do
    case Filament.Hold.acquire(server, request, holder_pid) do
      {:ok, token} ->
        token

      {:error, reason} ->
        raise Filament.HoldError,
          message: "use_hold acquisition rejected by #{inspect(server)}: #{inspect(reason)}",
          server: server,
          reason: reason
    end
  end

  @doc """
  Register an event handler function for the current fiber at the current render index.
  Returns the wire ref string `"fiber_id:handler_index"` to embed in phx-click/phx-submit.

  Called at render time by the `~F` template engine — do not call directly.
  """
  @spec register_event_handler(handler :: function()) :: wire_ref :: String.t()
  def register_event_handler(handler) when is_function(handler) do
    case Process.get(:filament_render_context) do
      nil ->
        # Called outside a Filament render pass — Phoenix's diff engine is
        # re-evaluating the previously-rendered struct's dynamic closure.
        # Return a stable ref using a per-process diff-phase counter so the
        # wire ref format stays valid (fiber_id:index). The real handlers were
        # already committed to the fiber tree during the render pass.
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
