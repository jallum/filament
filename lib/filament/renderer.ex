defmodule Filament.Renderer do
  @moduledoc false

  alias Filament.Fiber
  alias Filament.RenderContext
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
          {Rendered.t(), %{non_neg_integer() => term()}, list(), %{String.t() => Fiber.t()},
           %{non_neg_integer() => function()}}
  def render(component_module, props, %RenderContext{} = context) do
    # Apply prop defaults for any props not supplied.
    # Code.ensure_loaded is required because function_exported?/3 returns false
    # for modules that haven't been called yet, since modules load lazily on
    # their first function call — which happens later (component_module.render/1).
    Code.ensure_loaded(component_module)

    props =
      if function_exported?(component_module, :__props__, 0) do
        Enum.reduce(component_module.__props__(), props, fn {name, meta}, acc ->
          if Map.has_key?(acc, name) or meta.default == :__NO_DEFAULT__ do
            acc
          else
            Map.put(acc, name, meta.default)
          end
        end)
      else
        props
      end

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

      # If render returns a vnode instead of Rendered, recursively render it
      rendered =
        case result do
          %Rendered{} ->
            result

          vnode when is_tuple(vnode) ->
            render_vnode(vnode, context)

          _ ->
            raise ArgumentError,
                  "render/1 must return %Phoenix.LiveView.Rendered{} or vnode, got: #{inspect(result)}"
        end

      # Force evaluation of dynamic expressions so side effects like
      # register_event_handler run while the render context is active.
      _ = Phoenix.HTML.Safe.to_iodata(rendered)

      # Harvest context fields
      final_ctx = Process.get(:filament_render_context)

      # Seed the diff-eval state so that if Phoenix's diff engine re-evaluates
      # the rendered struct's dynamic closure outside our render context, any
      # register_event_handler calls return stable (non-crashing) wire refs.
      Process.put(:filament_diff_eval_state, {to_string(context.fiber_id), 0})

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

    rendered_child
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

  def render_vnode({:keyed_list, items}, context) do
    parent_fiber = Map.get(context.fiber_tree, context.fiber_id)
    old_children = if parent_fiber, do: parent_fiber.children, else: []

    {rendered_items, new_child_ids} =
      Enum.map_reduce(items, [], fn {key, vnode}, acc ->
        case vnode do
          {:component, mod, props, _key} ->
            rendered = render_vnode({:component, mod, props, key}, context)
            child_id = Fiber.child_id(parent_fiber, mod, {:key, key})
            {rendered, [child_id | acc]}

          _ ->
            {render_vnode(vnode, context), acc}
        end
      end)

    removed_children = old_children -- new_child_ids

    if removed_children != [] do
      ctx = Process.get(:filament_render_context)

      updated_fiber_tree =
        Enum.reduce(removed_children, ctx.new_fibers, fn child_id, acc ->
          case Map.get(acc, child_id) do
            nil ->
              case Map.get(context.fiber_tree, child_id) do
                nil -> acc
                existing -> Map.put(acc, child_id, %{existing | status: :unmounting})
              end

            fiber ->
              Map.put(acc, child_id, %{fiber | status: :unmounting})
          end
        end)

      Process.put(:filament_render_context, %{ctx | new_fibers: updated_fiber_tree})
    end

    rendered_items
  end

  def render_vnode(invalid, _context) do
    raise ArgumentError, "invalid vnode: #{inspect(invalid)}"
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
    Enum.map(attrs, fn {key, value} ->
      key_str = to_string(key)

      if String.starts_with?(key_str, "on_") do
        attr_key = "phx-" <> String.slice(key_str, 3..-1//1)
        wire_ref = Filament.Hooks.register_event_handler(value)
        [" ", attr_key, "=\"", wire_ref, "\""]
      else
        case value do
          false ->
            []

          true ->
            [" ", key_str]

          _ ->
            escaped_value = Plug.HTML.html_escape_to_iodata(to_string(value))
            [" ", key_str, "=\"", escaped_value, "\""]
        end
      end
    end)
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
