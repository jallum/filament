defmodule Filament.Renderer do
  @moduledoc """
  Pure render function that takes a component module and props and returns
  a %Phoenix.LiveView.Rendered{} struct.

  The renderer manages the render context (stored in the process dictionary)
  during component rendering to support hooks and fiber tracking.
  """

  alias Filament.{Fiber, RenderContext}

  @doc """
  Renders a component with the given props and context.

  ## Algorithm
  1. Validate props via __validate_props__!
  2. Set render context in process dictionary
  3. Call component.render(props)
  4. Collect new fibers from context
  5. Clear render context
  6. Return %Phoenix.LiveView.Rendered{}
  """
  @spec render(module(), map(), RenderContext.t()) :: Phoenix.LiveView.Rendered.t()
  def render(component_module, props, %RenderContext{} = context) do
    # Validate props
    if function_exported?(component_module, :__validate_props__!, 1) do
      component_module.__validate_props__!(props)
    end

    # Save current context (if any) and set new context
    previous_context = Process.get(:filament_render_context)
    Process.put(:filament_render_context, %{context | hook_index: 0})

    try do
      # Call render/1
      result = component_module.render(props)

      # If render returns a vnode instead of Rendered, recursively render it
      case result do
        %Phoenix.LiveView.Rendered{} -> result
        vnode when is_tuple(vnode) -> render_vnode(vnode, context)
        _ -> raise ArgumentError, "render/1 must return %Phoenix.LiveView.Rendered{} or vnode, got: #{inspect(result)}"
      end
    after
      # Restore or clear context
      if previous_context do
        Process.put(:filament_render_context, previous_context)
      else
        Process.delete(:filament_render_context)
      end
    end
  end

  @doc """
  Recursively renders a vnode tree into Rendered structs.
  """
  @spec render_vnode(Filament.VNode.t(), RenderContext.t()) :: term()
  def render_vnode({:text, content}, _context) do
    content
  end

  def render_vnode({:element, _tag, _attrs, children}, context) do
    Enum.map(children, &render_vnode(&1, context))
  end

  def render_vnode({:component, mod, props, key}, context) do
    # Generate child fiber ID
    parent_fiber = %Fiber{id: context.fiber_id, component: context.fiber_id}
    child_id = Fiber.child_id(parent_fiber, mod, if(key, do: {:key, key}, else: {:index, 0}))

    # Create child context
    child_context = %{context | fiber_id: child_id}

    # Render child component
    render(mod, props, child_context)
  end

  def render_vnode({:fragment, children}, context) do
    Enum.map(children, &render_vnode(&1, context))
  end

  def render_vnode({:keyed_list, items}, context) do
    Enum.map(items, fn {_key, vnode} -> render_vnode(vnode, context) end)
  end

  def render_vnode(invalid, _context) do
    raise ArgumentError, "invalid vnode: #{inspect(invalid)}"
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
    context = Process.get(:filament_render_context) ||
      raise "hook called outside render context"

    index = context.hook_index
    new_context = %{context | hook_index: index + 1}
    Process.put(:filament_render_context, new_context)

    {index, new_context}
  end
end
