defmodule Filament.Renderer do
  @moduledoc false

  alias Filament.Fiber
  alias Filament.RenderContext
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Rendered

  @doc """
  Renders a component with the given props and context.

  ## Algorithm
  1. Validate props via __validate_props__!
  2. Set render context in process dictionary (reset hook_index, new_hook_slots, pending_effects)
  3. Call component.render(props)
  4. Collect new fibers, hook slots, and effects from context
  5. Clear render context
  6. Return {Rendered, new_hook_slots, pending_effects, new_fibers}
  """
  @spec render(module(), map(), RenderContext.t()) ::
          {term(), %{non_neg_integer() => term()}, list(), %{String.t() => Fiber.t()},
           %{non_neg_integer() => function()}}
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
        hook_slots: hook_slots
    })

    try do
      # Call render/1
      result = component_module.render(props)

      # Normalize the component's render output to a walked vnode tree.
      #
      # `~F` returns a `%Rendered{}` struct: force-eval its dynamics so side
      # effects like `register_event_handler` run while the render context is
      # active, then wrap as `{:rendered_struct, r}` — a transitional vnode
      # shape that `Filament.Web.to_iodata/1` understands. Phase 1.4 will
      # switch `~F` codegen to emit walked vnode trees directly, eliminating
      # this wrapper.
      #
      # A vnode tuple is walked: child fibers are registered as a side effect
      # and the tree is returned in walked form (`:component` nodes carry
      # captured child render output).
      rendered =
        case result do
          %Rendered{} ->
            _ = Safe.to_iodata(result)
            {:rendered_struct, result}

          vnode when is_tuple(vnode) ->
            walk_vnode(vnode, context)

          _ ->
            raise ArgumentError,
                  "render/1 must return %Phoenix.LiveView.Rendered{} or vnode, got: #{inspect(result)}"
        end

      # Harvest context fields
      final_ctx = Process.get(:filament_render_context)

      {rendered, final_ctx.new_hook_slots, final_ctx.pending_effects, final_ctx.new_fibers,
       final_ctx.new_event_handlers}
    after
      # Always clear render context after render
      Process.delete(:filament_render_context)
    end
  end

  @doc """
  Renders a Filament child component within the current render pass, creating its
  own fiber and registering it as a child of the current fiber.

  Called by `Filament.TagEngine.component/3` when inside a Filament render pass
  so that sub-components get isolated fibers (and thus isolated hook state).
  """
  @spec render_component_child(RenderContext.t(), module(), map()) ::
          Rendered.t()
  def render_component_child(parent_ctx, mod, props) do
    indices = parent_ctx.child_component_indices
    index = Map.get(indices, mod, 0)
    parent_fiber = Map.get(parent_ctx.fiber_tree, parent_ctx.fiber_id)

    child_id =
      if parent_fiber do
        Fiber.child_id(parent_fiber, mod, {:index, index})
      else
        "#{parent_ctx.fiber_id}.#{mod}[#{index}]"
      end

    existing_fiber = Map.get(parent_ctx.fiber_tree, child_id)
    hook_slots = if existing_fiber, do: existing_fiber.hook_slots, else: %{}

    child_ctx = %RenderContext{
      fiber_id: child_id,
      fiber_tree: parent_ctx.fiber_tree,
      owner_pid: parent_ctx.owner_pid,
      new_fibers: %{},
      pending_effects: [],
      observable_stubs: parent_ctx.observable_stubs,
      subscribe_enabled: parent_ctx.subscribe_enabled,
      hook_index: 0,
      new_hook_slots: %{},
      event_handler_index: 0,
      new_event_handlers: %{},
      hook_slots: hook_slots
    }

    {rendered_child, child_new_hook_slots, child_pending_effects, grandchild_fibers, child_event_handlers} =
      render(mod, props, child_ctx)

    child_fiber = %Fiber{
      id: child_id,
      component: mod,
      props: props,
      hook_slots: Map.merge(hook_slots, child_new_hook_slots),
      event_handlers: child_event_handlers,
      children: Map.keys(grandchild_fibers),
      parent_id: parent_ctx.fiber_id,
      status: if(existing_fiber, do: :stable, else: :mounting)
    }

    updated_new_fibers =
      parent_ctx.new_fibers
      |> Map.put(child_id, child_fiber)
      |> Map.merge(grandchild_fibers)

    updated_ctx = %{
      parent_ctx
      | new_fibers: updated_new_fibers,
        pending_effects: parent_ctx.pending_effects ++ child_pending_effects,
        child_component_indices: Map.put(indices, mod, index + 1)
    }

    Process.put(:filament_render_context, updated_ctx)

    unwrap_for_embedding(rendered_child)
  end

  @doc """
  Like `render_component_child/3` but uses a caller-supplied key for fiber identity
  instead of a positional index. Used by `Filament.TagEngine.component_keyed/4`.
  """
  @spec render_component_child_keyed(RenderContext.t(), module(), map(), term()) :: Rendered.t()
  def render_component_child_keyed(parent_ctx, mod, props, key) do
    parent_fiber = Map.get(parent_ctx.fiber_tree, parent_ctx.fiber_id)

    child_id =
      if parent_fiber do
        Fiber.child_id(parent_fiber, mod, {:key, key})
      else
        "#{parent_ctx.fiber_id}.#{mod}[key=#{inspect(key)}]"
      end

    existing_fiber = Map.get(parent_ctx.fiber_tree, child_id)
    hook_slots = if existing_fiber, do: existing_fiber.hook_slots, else: %{}

    child_ctx = %RenderContext{
      fiber_id: child_id,
      fiber_tree: parent_ctx.fiber_tree,
      owner_pid: parent_ctx.owner_pid,
      new_fibers: %{},
      pending_effects: [],
      observable_stubs: parent_ctx.observable_stubs,
      subscribe_enabled: parent_ctx.subscribe_enabled,
      hook_index: 0,
      new_hook_slots: %{},
      event_handler_index: 0,
      new_event_handlers: %{},
      hook_slots: hook_slots
    }

    {rendered_child, child_new_hook_slots, child_pending_effects, grandchild_fibers, child_event_handlers} =
      render(mod, props, child_ctx)

    child_fiber = %Fiber{
      id: child_id,
      key: key,
      component: mod,
      props: props,
      hook_slots: Map.merge(hook_slots, child_new_hook_slots),
      event_handlers: child_event_handlers,
      children: Map.keys(grandchild_fibers),
      parent_id: parent_ctx.fiber_id,
      status: if(existing_fiber, do: :stable, else: :mounting)
    }

    updated_new_fibers =
      parent_ctx.new_fibers
      |> Map.put(child_id, child_fiber)
      |> Map.merge(grandchild_fibers)

    updated_ctx = %{
      parent_ctx
      | new_fibers: updated_new_fibers,
        pending_effects: parent_ctx.pending_effects ++ child_pending_effects
    }

    Process.put(:filament_render_context, updated_ctx)

    unwrap_for_embedding(rendered_child)
  end

  # Phase 1.2 transitional shim: TagEngine.component embeds the result of
  # `render_component_child*` directly into the parent `~F` template's
  # Rendered struct, where it expects either a `%Rendered{}` or iodata. Until
  # Phase 1.4 switches `~F` codegen, peel back the `{:rendered_struct, r}`
  # wrapper introduced by `render/3` so callers get the bare Rendered struct
  # they expect. Walked vnode trees are converted via the web converter.
  defp unwrap_for_embedding({:rendered_struct, %Phoenix.LiveView.Rendered{} = r}), do: r

  defp unwrap_for_embedding(other) when is_tuple(other) do
    {:safe, Filament.Web.to_iodata(other)}
  end

  defp unwrap_for_embedding(other), do: other

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

  @doc """
  Recursively renders a vnode tree into Rendered structs.
  """
  @spec render_vnode(Filament.VNode.t(), RenderContext.t()) :: term()
  def render_vnode({:text, content}, _context) do
    content
  end

  def render_vnode({:element, tag, attrs, children}, context) do
    tag_str = to_string(tag)
    rendered_children = Enum.map(children, &render_vnode(&1, context))

    if void_element?(tag_str) do
      ["<", tag_str, render_attrs(attrs), ">"]
    else
      ["<", tag_str, render_attrs(attrs), ">", rendered_children, "</", tag_str, ">"]
    end
  end

  def render_vnode({:component, mod, props, key}, context) do
    parent_fiber = Map.get(context.fiber_tree, context.fiber_id)
    discriminator = if key, do: {:key, key}, else: {:index, 0}
    child_id = Fiber.child_id(parent_fiber, mod, discriminator)
    existing_fiber = Map.get(context.fiber_tree, child_id)
    hook_slots = if existing_fiber, do: existing_fiber.hook_slots, else: %{}

    child_context = %RenderContext{
      fiber_id: child_id,
      fiber_tree: context.fiber_tree,
      owner_pid: context.owner_pid,
      new_fibers: %{},
      pending_effects: [],
      observable_stubs: context.observable_stubs,
      subscribe_enabled: context.subscribe_enabled,
      hook_index: 0,
      new_hook_slots: %{},
      event_handler_index: 0,
      new_event_handlers: %{},
      hook_slots: hook_slots
    }

    # Save parent context before child render/3 overwrites and deletes it
    parent_ctx = Process.get(:filament_render_context)

    {rendered_child, child_new_hook_slots, child_pending_effects, grandchild_fibers, child_event_handlers} =
      render(mod, props, child_context)

    child_fiber = %Fiber{
      id: child_id,
      key: key,
      component: mod,
      props: props,
      hook_slots: Map.merge(hook_slots, child_new_hook_slots),
      event_handlers: child_event_handlers,
      children: Map.keys(grandchild_fibers),
      parent_id: context.fiber_id,
      status: if(existing_fiber, do: :stable, else: :mounting)
    }

    # Restore parent context (deleted by render/3's after block) and update with child info
    updated_new_fibers =
      parent_ctx.new_fibers
      |> Map.put(child_id, child_fiber)
      |> Map.merge(grandchild_fibers)

    Process.put(:filament_render_context, %{
      parent_ctx
      | new_fibers: updated_new_fibers,
        pending_effects: parent_ctx.pending_effects ++ child_pending_effects
    })

    rendered_child
  end

  def render_vnode({:fragment, children}, context) do
    Enum.map(children, &render_vnode(&1, context))
  end

  def render_vnode(invalid, _context) do
    raise ArgumentError, "invalid vnode: #{inspect(invalid)}"
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

  defp void_element?("br"), do: true
  defp void_element?("hr"), do: true
  defp void_element?("input"), do: true
  defp void_element?("img"), do: true
  defp void_element?("meta"), do: true
  defp void_element?("link"), do: true
  defp void_element?("area"), do: true
  defp void_element?("base"), do: true
  defp void_element?("col"), do: true
  defp void_element?("embed"), do: true
  defp void_element?("param"), do: true
  defp void_element?("source"), do: true
  defp void_element?("track"), do: true
  defp void_element?("wbr"), do: true
  defp void_element?(_), do: false

  defp render_attrs([]), do: ""

  defp render_attrs(attrs) do
    {parts, _} =
      Enum.map_reduce(attrs, 0, fn {key, value}, on_idx ->
        key_str = to_string(key)

        if String.starts_with?(key_str, "on_") do
          attr_key = "phx-" <> String.slice(key_str, 3..-1//1)
          wire_ref = Filament.Hooks.event_at(on_idx, value)
          {[" ", attr_key, "=\"", wire_ref, "\""], on_idx + 1}
        else
          {render_attr_value(key_str, value), on_idx}
        end
      end)

    parts
  end

  defp render_attr_value(_key_str, false), do: []
  defp render_attr_value(key_str, true), do: [" ", key_str]

  defp render_attr_value(key_str, value) do
    escaped_value = Plug.HTML.html_escape_to_iodata(to_string(value))
    [" ", key_str, "=\"", escaped_value, "\""]
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
