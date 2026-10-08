defmodule Filament.Hooks do
  @moduledoc """
  Hooks for Filament components.

  ## Application-facing hooks

  Call these at the top level of `render/1`:

    - `use_state/1` — local mutable state; returns `{value, setter}`
    - `use_source/1` — bind a reactive source once (factory fn or cell tuple); returns a stable handle
    - `use_value/2` — read a projected value from a source and subscribe to its updates
    - `use_effect/2` — side-effect with optional cleanup
    - `event_at/2` — invoked by compiler-generated code from `~F` templates

  ## Pattern: use_source + use_value

  Bind the source once with `use_source`, then read values from it with `use_value`.
  This lets you pass the source to child components and apply multiple projections
  from the same source:

      def render(%{session_id: session_id}) do
        source = use_source(fn -> MyServer.cell(session_id) end)

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
    {index, previous, ctx} = use_slot(:uninitialized)

    slot =
      case previous do
        {:state, _value, _setter, _token} = slot ->
          slot

        _ ->
          # The token tells this mount's setter from one left by an earlier
          # mount at the same fiber id.
          token = make_ref()
          {:state, initial, build_setter(ctx.fiber_id, index, token, ctx.owner_pid), token}
      end

    commit_slot(index, slot)
    {:state, value, setter, _token} = slot
    {value, setter}
  end

  defp build_setter(fiber_id, slot_index, token, owner_pid) when is_pid(owner_pid) do
    fn new_value ->
      send(owner_pid, {:filament_set_state, fiber_id, slot_index, token, new_value})
      :ok
    end
  end

  defp build_setter(_fiber_id, _slot_index, _token, nil) do
    fn _new_value ->
      raise ArgumentError,
            "use_state setter called but the render had no :owner_pid. " <>
              "This usually means Reconciler.mount/2 or Reconciler.update/3 " <>
              "was invoked without the owner_pid: self() option."
    end
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

    # Declaration order; a child's effects sit where the child rendered.
    Process.put(:filament_render_context, %{ctx | pending_effects: [effect_entry | ctx.pending_effects]})
  end

  defp extract_fn_cleanup({_prev_deps, cleanup}) when is_function(cleanup, 0), do: cleanup
  defp extract_fn_cleanup(_), do: nil

  defp extract_cleanup({_prev_deps, cleanup}), do: cleanup
  defp extract_cleanup(_), do: nil

  @doc """
  Bind a reactive source once for the calling fiber and return a stable
  `%Filament.Source{}` struct.

  Accepts an existing source or a 0-arity factory fn that returns one.
  Parents bind the source once (e.g. via a session-keyed
  `ensure_started/1`) and pass the struct down to children that read
  their own projections via `use_value/2`.

      # Parent
      source = use_source(fn -> CartServer.cell(session_id) end)

      <Child source={source} />

      # Child
      count = use_value(source, fn
        :disconnected -> 0
        state         -> state.count
      end)

  Returns `nil` when sources are disconnected (static HTTP renders with
  `static_subscribe: false`). On subsequent
  renders, reuses the cached handle if its underlying transport is still
  reachable; calls the factory again otherwise (e.g. the GenServer behind
  the source crashed).

  The struct exposes the underlying transport data via `source.data` for
  components that need to invoke server actions in event handlers:

      on_click={fn -> CartServer.add_item(source.data, item) end}

  See `Filament.Source` for the struct shape and `Filament.Cell` for the
  transport behaviour.

  Must be called at the top level of `render/1` in consistent order.
  """
  @spec use_source(Filament.Source.t() | (-> Filament.Source.t())) :: Filament.Source.t() | nil
  def use_source(source_or_fn) when is_function(source_or_fn, 0) or is_struct(source_or_fn, Filament.Source) do
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    if ctx.sources == :disconnected do
      commit_slot(slot_index, :uninitialized)
      nil
    else
      source = resolve_source_factory(source_or_fn, previous)
      commit_slot(slot_index, {:cell_resolved, source})
      source
    end
  end

  defp resolve_source_factory(factory_fn, previous) when is_function(factory_fn, 0) do
    case previous do
      {:cell_resolved, %Filament.Source{} = cached} ->
        if Filament.Cell.whereis(cached), do: cached, else: factory_fn.()

      _ ->
        factory_fn.()
    end
  end

  defp resolve_source_factory(%Filament.Source{} = source, _previous), do: source

  @doc """
  Read a projected value from a source and subscribe to its updates.

  Generic over the source's transport — works against any module that implements
  `Filament.Cell` (the GenServer-backed observable, an in-process struct, a
  focus tracker, etc.). The component is unaware of how the source is fed.

  The hook subscribes with identity projection (the source delivers raw values)
  and applies the user-supplied `projection` at render time. A projection that
  closes over local component state always sees the current value.

  A static HTTP render reads the source's current value without subscribing.
  Returns `projection.(:disconnected)` when the source is `nil`, sources are
  disconnected, or the source can't reach its underlying state. An
  unreachable source is retried with backoff, and when the process behind a
  source exits (see `c:Filament.Cell.whereis/1`) the hook subscribes again,
  reaching a server restarted under the same name.

  ## Example

      defmodule Counter do
        use Filament.Observable.GenServer
        # ... handlers omitted ...
      end

      def render(%{counter: counter}) do
        source = Counter.cell(counter)

        count =
          use_value(source, fn
            :disconnected -> 0
            n -> n
          end)

        ~F"<p>{count}</p>"
      end

  Must be called at the top level of `render/1` in consistent order.
  """
  @spec use_value(Filament.Source.t() | nil, (term() | :disconnected -> term())) :: term()
  def use_value(cell, projection) when is_function(projection, 1) do
    {slot_index, previous, ctx} = use_slot(:uninitialized)

    if is_nil(cell) or ctx.sources != :subscribe do
      Filament.HookSlot.cleanup(previous)
      commit_slot(slot_index, :uninitialized)
      projection.(if cell && ctx.sources == :current, do: Filament.Cell.current(cell, & &1), else: :disconnected)
    else
      observable_subscribed(cell, projection, slot_index, previous, ctx)
    end
  end

  # The slot keeps this render's projection and value, so an update that
  # leaves the projected value unchanged can skip the next render.
  defp observable_subscribed(cell, projection, slot_index, previous, ctx) do
    subscription =
      case previous do
        {:cell_subscribed, ^cell, raw, subscriber, _projection, _value} ->
          {:ok, raw, subscriber}

        # A refresh keeps the subscription, and whatever the source holds for it.
        {:cell_resubscribe, ^cell, subscriber} ->
          observable_subscribe(cell, subscriber)

        _ ->
          Filament.HookSlot.cleanup(previous)
          observable_subscribe(cell, {ctx.owner_pid, ctx.fiber_id, slot_index, monitor_source(cell)})
      end

    case subscription do
      {:ok, raw, subscriber} ->
        value = projection.(raw)
        commit_slot(slot_index, {:cell_subscribed, cell, raw, subscriber, projection, value})
        value

      {:disconnected, subscriber} ->
        attempts =
          case previous do
            {:cell_retry, ^cell, _subscriber, n} -> n
            _ -> 0
          end

        retry_subscribe(ctx.owner_pid, subscriber, attempts)
        commit_slot(slot_index, {:cell_retry, cell, subscriber, attempts + 1})
        projection.(:disconnected)
    end
  end

  defp observable_subscribe(cell, subscriber) do
    case Filament.Cell.subscribe(cell, subscriber, &Function.identity/1) do
      {:ok, raw} -> {:ok, raw, subscriber}
      :disconnected -> {:disconnected, subscriber}
    end
  end

  # The subscriber's ref monitors the source's process, so the owner hears
  # `{:cell_resubscribe, ref, :process, pid, reason}` when it exits and
  # subscribes again, reaching a restarted server.
  defp monitor_source(cell) do
    case Filament.Cell.whereis(cell) do
      process when is_pid(process) or is_tuple(process) -> :erlang.monitor(:process, process, tag: :cell_resubscribe)
      _ -> make_ref()
    end
  end

  @retry_ms 100
  @max_retry_ms 5_000

  # Ask the owner to try again after a backoff, so a source that isn't
  # running yet, or is restarting, connects once it's up. The message has the
  # shape of the source's exit, so either finds the slot by its ref.
  defp retry_subscribe(owner, {_owner, _fiber_id, _slot, ref}, attempts) when is_pid(owner) do
    delay = min(@retry_ms * Integer.pow(2, min(attempts, 6)), @max_retry_ms)
    Process.send_after(owner, {:cell_resubscribe, ref, :process, nil, :retry}, delay)
  end

  defp retry_subscribe(_owner, _subscriber, _attempts), do: :ok

  @doc """
  Register a bubble or capture-phase event handler at the next slot.

  `kinds` is `:all` (default) or a `MapSet` of atoms. `Filament.Core.dispatch_event/5`
  fires the handler only when the dispatched kind matches the kinds-set.
  Backwards-compatible: 1- and 2-arity calls keep working with `kinds = :all`.
  """
  @spec register_event_handler(function()) :: String.t()
  @spec register_event_handler(function(), :bubble | :capture) :: String.t()
  @spec register_event_handler(function(), :bubble | :capture, :all | MapSet.t(atom())) ::
          String.t()
  def register_event_handler(handler, phase \\ :bubble, kinds \\ :all)
      when is_function(handler) and phase in [:bubble, :capture] do
    ctx =
      Process.get(:filament_render_context) ||
        raise ArgumentError, "hook called outside a render pass — hooks may only be called from render/1"

    fiber_id_str = to_string(ctx.fiber_id)
    {idx, new_ctx} = advance_handler_index(ctx, phase, handler, kinds)
    Process.put(:filament_render_context, new_ctx)
    "#{fiber_id_str}:#{idx}"
  end

  defp advance_handler_index(ctx, :bubble, handler, kinds) do
    idx = ctx.event_handler_index

    new_ctx = %{
      ctx
      | event_handler_index: idx + 1,
        new_event_handlers: Map.put(ctx.new_event_handlers, idx, {handler, kinds})
    }

    {idx, new_ctx}
  end

  defp advance_handler_index(ctx, :capture, handler, kinds) do
    idx = ctx.capture_handler_index

    new_ctx = %{
      ctx
      | capture_handler_index: idx + 1,
        new_capture_handlers: Map.put(ctx.new_capture_handlers, idx, {handler, kinds})
    }

    {idx, new_ctx}
  end

  @doc false
  # A wire ref's fiber id and handler index (`register_event_handler/1`).
  # The index is digits only, so the last colon is the separator, whatever
  # the fiber id holds: a keyed child's key may have colons of its own.
  @spec parse_event_ref(String.t()) :: {:ok, String.t(), non_neg_integer()} | :error
  def parse_event_ref(ref) when is_binary(ref) do
    case :binary.matches(ref, ":") do
      [] ->
        :error

      matches ->
        {at, 1} = List.last(matches)
        index = binary_part(ref, at + 1, byte_size(ref) - at - 1)

        case Integer.parse(index) do
          {idx, ""} when idx >= 0 -> {:ok, binary_part(ref, 0, at), idx}
          _ -> :error
        end
    end
  end
end
