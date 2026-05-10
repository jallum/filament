defmodule Filament.Hooks do
  @moduledoc """
  Hooks for Filament components.

  ## Application-facing hooks

  Call these at the top level of `render/1`:

    - `use_state/1` — local mutable state; returns `{value, setter}`
    - `use_source/1` — bind a reactive source once (factory fn or cell tuple); returns a stable handle
    - `use_value/2` — read a projected value from a source and subscribe to its updates
    - `use_effect/2` — side-effect with optional cleanup
    - `memo_at/3` and `event_at/2` — invoked by compiler-generated code from `~F` templates

  ## Pattern: use_source + use_value

  Bind the source once with `use_source`, then read values from it with `use_value`.
  This lets you pass the source to child components and apply multiple projections
  from the same source:

      def render(%{session_id: session_id}) do
        source = use_source(fn ->
          {Filament.Observable.GenServer, MyServer.start_link(session_id)}
        end)

        count = use_value(source, fn
          :disconnected -> 0
          state -> state.count
        end)

        <ChildComponent source={source} />
      end

      # In the child:
      def render(%{source: source}) do
        value = use_value(source, fn
          :disconnected -> nil
          s -> s.some_field
        end)
      end

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
  Bind a reactive source once for the calling fiber and return a stable handle.

  Accepts a source tuple `{transport, data}` or a 0-arity factory fn that
  returns one. Parents bind the source once (e.g. via a session-keyed
  `ensure_started/1`) and pass the handle down to children that read their
  own projections via `use_value/2`.

      # Parent
      source = use_source(fn ->
        {Filament.Observable.GenServer, CartServer.ensure_started(session_id)}
      end)

      <Child source={source} />

      # Child
      count = use_value(source, fn
        :disconnected -> 0
        state         -> state.count
      end)

  Returns `nil` during disconnected (static HTTP) renders. On subsequent
  renders, reuses the cached handle if its underlying transport is still
  reachable; calls the factory again otherwise (e.g. the GenServer behind
  the source crashed).

  The handle is a `Filament.Cell.t()` — see `Filament.Cell` for the transport
  contract; "source" is the user-facing name for the same value.

  Must be called at the top level of `render/1` in consistent order.
  """
  @spec use_source(Filament.Cell.t() | (-> Filament.Cell.t())) :: Filament.Cell.t() | nil
  def use_source(cell_or_fn) when is_function(cell_or_fn, 0) or is_tuple(cell_or_fn) do
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    if ctx.subscribe_enabled do
      cell = resolve_observable_factory(cell_or_fn, previous)
      commit_slot(slot_index, {:cell_resolved, cell})
      cell
    else
      commit_slot(slot_index, :uninitialized)
      nil
    end
  end

  defp resolve_observable_factory(factory_fn, previous) when is_function(factory_fn, 0) do
    case previous do
      {:cell_resolved, cached} ->
        if observable_reachable?(cached), do: cached, else: factory_fn.()

      _ ->
        factory_fn.()
    end
  end

  defp resolve_observable_factory(cell, _previous) when is_tuple(cell), do: cell

  defp observable_reachable?({Filament.Observable.GenServer, pid}) when is_pid(pid), do: Process.alive?(pid)

  defp observable_reachable?(_), do: true

  @doc """
  Read a projected value from a source and subscribe to its updates.

  Generic over the source's transport — works against any module that implements
  `Filament.Cell` (the GenServer-backed observable, an in-process struct, a
  focus tracker, etc.). The component is unaware of how the source is fed.

  The hook subscribes with identity projection (the source delivers raw values)
  and applies the user-supplied `projection` at render time. A projection that
  closes over local component state always sees the current value.

  Returns `projection.(:disconnected)` during static (HTTP) renders and when
  the source can't reach its underlying state.

  ## Example

      defmodule Counter do
        use Filament.Observable.GenServer
        # ... handlers omitted ...
      end

      def render(%{counter: counter}) do
        source = {Filament.Observable.GenServer, counter}

        count =
          use_value(source, fn
            :disconnected -> 0
            n -> n
          end)

        ~F"<p>{count}</p>"
      end

  Must be called at the top level of `render/1` in consistent order.
  """
  @spec use_value(Filament.Cell.t() | nil, (term() | :disconnected -> term())) :: term()
  def use_value(cell, projection) when is_function(projection, 1) do
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    cond do
      not ctx.subscribe_enabled ->
        commit_slot(slot_index, :uninitialized)
        projection.(:disconnected)

      is_nil(cell) ->
        commit_slot(slot_index, :uninitialized)
        projection.(:disconnected)

      true ->
        observable_subscribed(cell, projection, slot_index, previous, ctx)
    end
  end

  defp observable_subscribed(cell, projection, slot_index, previous, ctx) do
    case resolve_observable_value(cell, slot_index, previous, ctx) do
      :disconnected ->
        commit_slot(slot_index, :uninitialized)
        projection.(:disconnected)

      raw ->
        commit_slot(slot_index, {:cell_subscribed, cell, raw})
        projection.(raw)
    end
  end

  # Read the cell's raw value: prefer the fresher value from `new_hook_slots`
  # (set by an in-flight `:cell_update`), fall back to the previously cached
  # value, or subscribe fresh on first render. The slot tag carries the cell
  # identity so a cell swap across renders triggers an unsubscribe + fresh
  # subscribe rather than silently feeding values from the old transport.
  defp resolve_observable_value(cell, slot_index, previous, ctx) do
    case Map.get(ctx.new_hook_slots, slot_index) do
      {:cell_subscribed, ^cell, raw} ->
        raw

      {:cell_subscribed, _other, _raw} ->
        observable_subscribe_fresh(cell, slot_index, ctx)

      _ ->
        case previous do
          {:cell_subscribed, ^cell, raw} ->
            raw

          {:cell_subscribed, old_cell, _raw} ->
            maybe_unsubscribe_observable(ctx, old_cell, slot_index)
            observable_subscribe_fresh(cell, slot_index, ctx)

          _ ->
            observable_subscribe_fresh(cell, slot_index, ctx)
        end
    end
  end

  defp maybe_unsubscribe_observable(ctx, old_cell, slot_index) do
    if is_map_key(ctx.fiber_tree, ctx.fiber_id) do
      subscriber = {ctx.owner_pid, ctx.fiber_id, slot_index}
      Filament.Cell.unsubscribe(old_cell, subscriber)
    end
  end

  defp observable_subscribe_fresh(cell, slot_index, ctx) do
    subscriber = {ctx.owner_pid, ctx.fiber_id, slot_index}

    case Filament.Cell.subscribe(cell, subscriber, &Function.identity/1) do
      {:ok, value} -> value
      :disconnected -> :disconnected
    end
  end

  @doc false
  @spec event_at(non_neg_integer(), function()) :: String.t()
  @spec event_at(non_neg_integer(), function(), :bubble | :capture) :: String.t()
  def event_at(slot, handler, phase \\ :bubble) when is_function(handler) and phase in [:bubble, :capture] do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError, "hook called outside a render pass — hooks may only be called from render/1"

    fiber_id_str = to_string(ctx.fiber_id)
    new_ctx = put_handler(ctx, phase, slot, handler)
    Process.put(:filament_render_context, new_ctx)
    "#{fiber_id_str}:#{slot}"
  end

  defp put_handler(ctx, :bubble, slot, handler) do
    %{ctx | new_event_handlers: Map.put(ctx.new_event_handlers, slot, handler)}
  end

  defp put_handler(ctx, :capture, slot, handler) do
    %{ctx | new_capture_handlers: Map.put(ctx.new_capture_handlers, slot, handler)}
  end

  @doc false
  @spec register_event_handler(function()) :: String.t()
  @spec register_event_handler(function(), :bubble | :capture) :: String.t()
  def register_event_handler(handler, phase \\ :bubble) when is_function(handler) and phase in [:bubble, :capture] do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError, "hook called outside a render pass — hooks may only be called from render/1"

    fiber_id_str = to_string(ctx.fiber_id)
    {idx, new_ctx} = advance_handler_index(ctx, phase, handler)
    Process.put(:filament_render_context, new_ctx)
    "#{fiber_id_str}:#{idx}"
  end

  defp advance_handler_index(ctx, :bubble, handler) do
    idx = ctx.event_handler_index

    new_ctx = %{
      ctx
      | event_handler_index: idx + 1,
        new_event_handlers: Map.put(ctx.new_event_handlers, idx, handler)
    }

    {idx, new_ctx}
  end

  defp advance_handler_index(ctx, :capture, handler) do
    idx = ctx.capture_handler_index

    new_ctx = %{
      ctx
      | capture_handler_index: idx + 1,
        new_capture_handlers: Map.put(ctx.new_capture_handlers, idx, handler)
    }

    {idx, new_ctx}
  end
end
