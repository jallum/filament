defmodule Filament.Renderer do
  @moduledoc false

  alias Filament.Fiber
  alias Filament.RenderContext

  @doc """
  Render `fiber` with `props`, or reuse its stored output when `reusable?/2`.

  Returns the updated fiber and the pass's final context. The context's
  `new_fibers` and `pending_effects` accumulate across the pass: `context`
  carries in what came before, and every fiber rendered or rewalked below
  `fiber` adds its entry and effects (newest first). A clean subtree adds
  nothing, since the tree already holds it.
  """
  @spec render_fiber(Fiber.t(), map(), RenderContext.t()) :: {Fiber.t(), RenderContext.t()}
  def render_fiber(fiber, props, context) do
    cond do
      not reusable?(fiber, props) ->
        {rendered, ctx} = render(fiber.component, props, %{context | hook_slots: fiber.hook_slots})

        {%{
           fiber
           | props: props,
             hook_slots: ctx.new_hook_slots,
             event_handlers: ctx.new_event_handlers,
             capture_handlers: ctx.new_capture_handlers,
             children: Enum.reverse(ctx.children),
             rendered: rendered,
             dirty: nil
         }, ctx}

      fiber.dirty == nil ->
        {fiber, context}

      # Only descendants are dirty: walk the stored output again so each
      # child component renders or is reused.
      true ->
        {rendered, ctx} = in_context(context, fn -> rewalk(fiber.rendered) end)
        {%{fiber | children: Enum.reverse(ctx.children), rendered: rendered, dirty: nil}, ctx}
    end
  end

  @doc """
  Whether `fiber` can skip its render: it has a stored output, its props are
  unchanged (`===`), and neither its own state nor a value it reads changed.
  Closures in props compare equal when they come from the same code and
  capture equal values.
  """
  @spec reusable?(Fiber.t(), map()) :: boolean()
  def reusable?(%Fiber{props: old_props, dirty: dirty, rendered: rendered}, props),
    do: old_props === props and dirty != :self and rendered != :unrendered

  # Validates props, then calls render/1 and walks its output with `context`
  # as the current render context.
  defp render(component_module, props, context) do
    # function_exported?/3 is false until the module is loaded.
    Code.ensure_loaded(component_module)
    props = apply_prop_defaults(component_module, props)

    if function_exported?(component_module, :__validate_props__!, 1) do
      component_module.__validate_props__!(props)
    end

    in_context(%{context | props: props}, fn -> walk_child(component_module.render(props), context) end)
  end

  defp in_context(context, fun) do
    Process.put(:filament_render_context, context)

    try do
      result = fun.()
      {result, Process.get(:filament_render_context)}
    after
      Process.delete(:filament_render_context)
    end
  end

  @doc """
  Render a child component inside the current render pass. The child gets its
  own fiber (so its hooks are isolated), identified by its parent, module and
  `key`, or its position among the parent's children of that module when
  `key` is `nil`. Returns the child's output.
  """
  @spec render_component_child(RenderContext.t(), module(), map(), term() | nil) :: term()
  def render_component_child(parent_ctx, mod, props, key \\ nil) do
    {discriminator, indices} = child_discriminator(parent_ctx, mod, key)
    child_id = Fiber.child_id(parent_ctx.fiber_id, mod, discriminator)

    # Siblings with one key would share a fiber, and with it their state.
    if Map.has_key?(parent_ctx.new_fibers, child_id) do
      raise ArgumentError,
            "duplicate key #{inspect(key)} for #{inspect(mod)} in fiber #{parent_ctx.fiber_id}: keys must be " <>
              "unique among the #{inspect(mod)} children a component renders, across all its lists"
    end

    fiber =
      Map.get(parent_ctx.fiber_tree, child_id) ||
        Fiber.new(id: child_id, component: mod, parent_id: parent_ctx.fiber_id)

    child_ctx = %RenderContext{
      fiber_id: child_id,
      fiber_tree: parent_ctx.fiber_tree,
      owner_pid: parent_ctx.owner_pid,
      sources: parent_ctx.sources,
      target: parent_ctx.target,
      new_fibers: parent_ctx.new_fibers,
      pending_effects: parent_ctx.pending_effects
    }

    {child, ctx} = render_fiber(fiber, props, child_ctx)

    Process.put(:filament_render_context, %{
      parent_ctx
      | new_fibers: Map.put(ctx.new_fibers, child_id, child),
        pending_effects: ctx.pending_effects,
        children: [child_id | parent_ctx.children],
        child_component_indices: indices
    })

    child.rendered
  end

  # Walked output keeps event refs resolved and child output inline, so only
  # `:component` nodes need visiting. Child ids come out the same as in the
  # original render because the component nodes are visited in the same order.
  defp rewalk({:component, mod, props, key, _child_render}) do
    {:component, mod, props, key, render_component_child(Process.get(:filament_render_context), mod, props, key || nil)}
  end

  # Compiled templates hold child output in their child bindings.
  defp rewalk(%Filament.Template{bindings: bindings, values: values} = plan) do
    values =
      Enum.zip_with(bindings, values, fn
        {kind, _key}, value when kind in [:child, :components] -> rewalk(value)
        _, value -> value
      end)

    %{plan | values: values}
  end

  defp rewalk({:element, tag, attrs, children}), do: {:element, tag, attrs, rewalk(children)}
  defp rewalk({:fragment, children}), do: {:fragment, rewalk(children)}
  defp rewalk(nodes) when is_list(nodes), do: Enum.map(nodes, &rewalk/1)
  defp rewalk(node), do: node

  defp child_discriminator(parent_ctx, mod, nil) do
    indices = parent_ctx.child_component_indices
    index = Map.get(indices, mod, 0)
    {{:index, index}, Map.put(indices, mod, index + 1)}
  end

  defp child_discriminator(parent_ctx, _mod, key) do
    {{:key, key}, parent_ctx.child_component_indices}
  end

  @doc """
  Substrate-only walk of a vnode tree.

  Visits each node, recurses into `:element` and `:fragment` children, and for
  `:component` nodes runs the substrate side effect (child fiber registration
  via `render_component_child/4`).

  Returns a *walked* vnode tree: same shape as the input except `:component`
  nodes are rewritten to a 5-tuple `{:component, mod, props, key, child_render}`
  carrying the child component's render output. The web-bound conversion to
  HTML iodata is the converter's job (Phase 1.3); this walker emits no HTML,
  no `phx-event` strings, no escapes.
  """
  @spec walk_vnode(Filament.VNode.t(), RenderContext.t()) :: term()
  def walk_vnode({:text, _content} = node, _context), do: node
  def walk_vnode({:safe, _iodata} = safe, _context), do: safe

  def walk_vnode({:element, tag, attrs, children}, context) do
    resolved_attrs = Enum.map(attrs, &resolve_event_attr/1)
    walked = Enum.map(children, &walk_child(&1, context))
    {:element, tag, resolved_attrs, walked}
  end

  def walk_vnode({:component, mod, props, key}, _context) do
    parent_ctx = Process.get(:filament_render_context)

    child_render = render_component_child(parent_ctx, mod, props, key || nil)

    {:component, mod, props, key, child_render}
  end

  def walk_vnode({:fragment, children}, context) do
    walked = Enum.map(children, &walk_child(&1, context))
    {:fragment, walked}
  end

  def walk_vnode({:slot, _name, [], nil}, _context) do
    {:fragment, []}
  end

  def walk_vnode({:slot, _name, [], default_mod}, context) when not is_nil(default_mod) do
    walk_vnode({:component, default_mod, %{}, nil}, context)
  end

  def walk_vnode({:slot, _name, entries, _default}, context) do
    children =
      Enum.map(entries, fn %Filament.Slot.Entry{render_fn: f} ->
        walk_child(f.(), context)
      end)

    {:fragment, children}
  end

  def walk_vnode(invalid, _context) do
    raise ArgumentError, "invalid vnode: #{inspect(invalid)}"
  end

  @doc false
  def walk_value(value, context), do: walk_child(value, context)

  # Element/fragment children may include scalar values (a string interpolation
  # `{name}`, a number, etc.) alongside vnode tuples. Tuples recurse through
  # the walker; scalars pass through and are stringified/escaped by
  # `Filament.Web.to_iodata`.
  defp walk_child(%Filament.Template{} = template, context), do: Filament.Template.walk(template, context)
  defp walk_child(children, context) when is_list(children), do: Enum.map(children, &walk_child(&1, context))
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

  @doc false
  def current_props do
    case Process.get(:filament_render_context) do
      %RenderContext{props: props} -> props
      nil -> raise "render props requested outside render context"
    end
  end
end
