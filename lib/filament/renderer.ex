defmodule Filament.Renderer do
  @moduledoc false

  alias Filament.Fiber
  alias Filament.RenderContext

  @doc """
  Renders a component with the given props and context.

  ## Algorithm
  1. Validate props via __validate_props__!
  2. Set render context in process dictionary (reset hook_index, new_hook_slots, pending_effects)
  3. Call component.render(props)
  4. Collect new fibers, hook slots, and effects from context
  5. Clear render context
  6. Return the 6-tuple of rendered output and accumulated context fields.
  """
  @spec render(module(), map(), RenderContext.t()) ::
          {term(), %{non_neg_integer() => term()}, list(), %{String.t() => Fiber.t()},
           %{non_neg_integer() => function()}, %{non_neg_integer() => function()}}
  def render(component_module, props, %RenderContext{} = context) do
    # Apply prop defaults for any props not supplied.
    # Code.ensure_loaded is required because function_exported?/3 returns false
    # for modules that haven't been called yet, since modules load lazily on
    # their first function call — which happens later (component_module.render/1).
    Code.ensure_loaded(component_module)

    props = apply_prop_defaults(component_module, props)

    # Validate props
    if function_exported?(component_module, :__validate_props__!, 1) do
      component_module.__validate_props__!(props)
    end

    # Look up existing fiber for hook state continuity
    existing_fiber = Map.get(context.fiber_tree, context.fiber_id)
    hook_slots = if existing_fiber, do: existing_fiber.hook_slots, else: %{}

    # Save current context (if any) and set new context with reset state
    Process.put(:filament_render_context, %{
      context
      | hook_index: 0,
        new_hook_slots: %{},
        pending_effects: [],
        event_handler_index: 0,
        new_event_handlers: %{},
        capture_handler_index: 0,
        new_capture_handlers: %{},
        hook_slots: hook_slots
    })

    try do
      # `~F` emits walked vnode tuples via `Filament.VNodeEngine`. A component's
      # render/1 either returns a vnode tuple (which we walk for fiber
      # registration) or a scalar value (passed through as-is for the
      # embedder/web converter to render).
      rendered =
        case component_module.render(props) do
          vnode when is_tuple(vnode) -> walk_vnode(vnode, context)
          other -> other
        end

      final_ctx = Process.get(:filament_render_context)

      {rendered, final_ctx.new_hook_slots, final_ctx.pending_effects, final_ctx.new_fibers,
       final_ctx.new_event_handlers, final_ctx.new_capture_handlers}
    after
      Process.delete(:filament_render_context)
    end
  end

  @doc """
  Render a child component inside the current render pass. The child gets its
  own fiber (so its hooks are isolated) and is registered against the parent
  fiber. `key` is `nil` for positional children (`<Item />` inside a stable
  shape) and a user-supplied term for keyed children (`<Item :for=... :key=...>`)
  — the discriminator drives child fiber identity, which determines whether
  hook state survives reorders.

  Returns whatever the child's render/1 produced; the caller embeds it on the
  parent's `:component` vnode 5-tuple for the web converter to render.
  """
  @spec render_component_child(RenderContext.t(), module(), map(), term() | nil) :: term()
  def render_component_child(parent_ctx, mod, props, key \\ nil) do
    {discriminator, indices_after} = child_discriminator(parent_ctx, mod, key)
    child_id = compute_child_id(parent_ctx, mod, discriminator)
    existing_fiber = Map.get(parent_ctx.fiber_tree, child_id)
    hook_slots = if existing_fiber, do: existing_fiber.hook_slots, else: %{}

    child_ctx = %RenderContext{
      fiber_id: child_id,
      fiber_tree: parent_ctx.fiber_tree,
      owner_pid: parent_ctx.owner_pid,
      subscribe_enabled: parent_ctx.subscribe_enabled,
      hook_slots: hook_slots
    }

    {rendered_child, child_new_hook_slots, child_pending_effects, grandchild_fibers,
     child_event_handlers, child_capture_handlers} =
      render(mod, props, child_ctx)

    child_fiber = %Fiber{
      id: child_id,
      key: key,
      component: mod,
      props: props,
      hook_slots: Map.merge(hook_slots, child_new_hook_slots),
      event_handlers: child_event_handlers,
      capture_handlers: child_capture_handlers,
      children: Map.keys(grandchild_fibers),
      parent_id: parent_ctx.fiber_id,
      status: if(existing_fiber, do: :stable, else: :mounting)
    }

    updated_new_fibers =
      parent_ctx.new_fibers
      |> Map.put(child_id, child_fiber)
      |> Map.merge(grandchild_fibers)

    Process.put(:filament_render_context, %{
      parent_ctx
      | new_fibers: updated_new_fibers,
        pending_effects: parent_ctx.pending_effects ++ child_pending_effects,
        child_component_indices: indices_after
    })

    rendered_child
  end

  @doc false
  @spec render_component_child_keyed(RenderContext.t(), module(), map(), term()) :: term()
  def render_component_child_keyed(parent_ctx, mod, props, key) do
    render_component_child(parent_ctx, mod, props, key)
  end

  defp child_discriminator(parent_ctx, mod, nil) do
    indices = parent_ctx.child_component_indices
    index = Map.get(indices, mod, 0)
    {{:index, index}, Map.put(indices, mod, index + 1)}
  end

  defp child_discriminator(parent_ctx, _mod, key) do
    {{:key, key}, parent_ctx.child_component_indices}
  end

  defp compute_child_id(parent_ctx, mod, discriminator) do
    parent_fiber = Map.get(parent_ctx.fiber_tree, parent_ctx.fiber_id)

    if parent_fiber do
      Fiber.child_id(parent_fiber, mod, discriminator)
    else
      fallback_child_id(parent_ctx.fiber_id, mod, discriminator)
    end
  end

  defp fallback_child_id(parent_id, mod, {:index, index}),
    do: "#{parent_id}.#{mod}[#{index}]"

  defp fallback_child_id(parent_id, mod, {:key, key}),
    do: "#{parent_id}.#{mod}[key=#{inspect(key)}]"

  @doc """
  Substrate-only walk of a vnode tree.

  Visits each node, recurses into `:element` and `:fragment` children, and for
  `:component` nodes runs the substrate side effect (child fiber registration
  via `render_component_child/3` or `render_component_child_keyed/4`).

  Returns a *walked* vnode tree: same shape as the input except `:component`
  nodes are rewritten to a 5-tuple `{:component, mod, props, key, child_render}`
  carrying the child component's render output. The web-bound conversion to
  HTML iodata is the converter's job (Phase 1.3); this walker emits no HTML,
  no `phx-event` strings, no escapes.
  """
  @spec walk_vnode(Filament.VNode.t(), RenderContext.t()) :: term()
  def walk_vnode({:text, _content} = node, _context), do: node

  def walk_vnode({:element, tag, attrs, children}, context) do
    resolved_attrs = Enum.map(attrs, &resolve_event_attr/1)
    walked = Enum.map(children, &walk_child(&1, context))
    {:element, tag, resolved_attrs, walked}
  end

  def walk_vnode({:component, mod, props, key}, _context) do
    parent_ctx = Process.get(:filament_render_context)

    child_render =
      if key do
        render_component_child_keyed(parent_ctx, mod, props, key)
      else
        render_component_child(parent_ctx, mod, props)
      end

    {:component, mod, props, key, child_render}
  end

  def walk_vnode({:fragment, children}, context) do
    walked = Enum.map(children, &walk_child(&1, context))
    {:fragment, walked}
  end

  def walk_vnode(invalid, _context) do
    raise ArgumentError, "invalid vnode: #{inspect(invalid)}"
  end

  # Element/fragment children may include scalar values (a string interpolation
  # `{name}`, a number, etc.) alongside vnode tuples. Tuples recurse through
  # the walker; scalars pass through and are stringified/escaped by
  # `Filament.Web.to_iodata`.
  defp walk_child(child, context) when is_tuple(child), do: walk_vnode(child, context)
  defp walk_child(child, _context), do: child

  # Substrate-side resolution of `on_*` attribute handlers: registers the
  # closure as an event handler under the active fiber and replaces the
  # function value with a `{:wire_ref, ref_string}` marker. The web converter
  # consumes the marker and emits the corresponding `phx-*` attribute.
  defp resolve_event_attr({key, value} = attr) do
    if is_function(value) and String.starts_with?(to_string(key), "on_") do
      wire_ref = Filament.Hooks.register_event_handler(value)
      {key, {:wire_ref, wire_ref}}
    else
      attr
    end
  end

  defp apply_prop_defaults(component_module, props) do
    if function_exported?(component_module, :__props__, 0) do
      Enum.reduce(component_module.__props__(), props, &apply_single_default(&1, &2))
    else
      props
    end
  end

  defp apply_single_default({name, meta}, acc) do
    if Map.has_key?(acc, name) or meta.default == :__NO_DEFAULT__ do
      acc
    else
      Map.put(acc, name, meta.default)
    end
  end

  @doc """
  Returns the current render context from the process dictionary.
  """
  @spec current_context() :: RenderContext.t() | nil
  def current_context do
    Process.get(:filament_render_context)
  end

  @doc """
  Gets the next hook slot index and increments the counter.

  ## Examples

      iex> {index, _ctx} = Filament.Renderer.next_hook_slot()
      iex> index
      0

      iex> {index, _ctx} = Filament.Renderer.next_hook_slot()
      iex> index
      1
  """
  @spec next_hook_slot() :: {non_neg_integer(), RenderContext.t()}
  def next_hook_slot do
    context =
      Process.get(:filament_render_context) ||
        raise "hook called outside render context"

    index = context.hook_index
    new_context = %{context | hook_index: index + 1}
    Process.put(:filament_render_context, new_context)

    {index, new_context}
  end
end
