defmodule Filament.Reconciler do
  @moduledoc """
  Fiber tree reconciler that manages component instances across renders.

  The reconciler tracks component instances, preserves hook state by matching
  fiber IDs, and manages mount/update/unmount lifecycle.
  """

  alias Filament.{Fiber, RenderContext, Renderer, ReconcilerError}

  @type fiber_tree() :: %{String.t() => Fiber.t()}

  @doc """
  Mounts the root component and creates the initial fiber tree.
  """
  @spec mount(module(), map()) :: {fiber_tree(), Phoenix.LiveView.Rendered.t()}
  def mount(root_component, props) do
    # Create root fiber
    root_fiber =
      Fiber.new(
        id: "root",
        component: root_component,
        props: props,
        status: :mounting
      )

    # Create initial context
    context = %RenderContext{
      fiber_id: "root",
      fiber_tree: %{},
      new_fibers: %{}
    }

    # Render the component
    rendered = Renderer.render(root_component, props, context)

    # Build initial tree with root and any discovered children
    tree =
      %{"root" => %{root_fiber | status: :stable}}
      |> Map.merge(context.new_fibers)
      |> Enum.map(fn {id, fiber} ->
        {id, %{fiber | status: :stable}}
      end)
      |> Map.new()

    {tree, rendered}
  end

  @doc """
  Updates a fiber with new props and reconciles children.
  """
  @spec update(fiber_tree(), String.t(), map()) :: {fiber_tree(), Phoenix.LiveView.Rendered.t()}
  def update(tree, fiber_id, new_props) do
    # Fetch fiber
    fiber =
      Map.get(tree, fiber_id) ||
        raise ReconcilerError, "fiber #{inspect(fiber_id)} not found in tree"

    # Update fiber props and status
    updated_fiber = %{fiber | props: new_props, status: :updating}

    # Create context for re-render
    context = %RenderContext{
      fiber_id: fiber_id,
      fiber_tree: tree,
      new_fibers: %{}
    }

    # Re-render component
    rendered = Renderer.render(fiber.component, new_props, context)

    # Create new tree with updated fiber
    new_tree = Map.put(tree, fiber_id, updated_fiber)

    # Reconcile children
    final_tree =
      reconcile_children(new_tree, fiber_id, updated_fiber, context)
      |> Map.update!(fiber_id, &%{&1 | status: :stable})

    {final_tree, rendered}
  end

  @doc """
  Marks all fibers as unmounting.
  """
  @spec unmount(fiber_tree()) :: :ok
  def unmount(tree) do
    tree
    |> Map.values()
    |> Enum.each(fn fiber ->
      %{fiber | status: :unmounting}
    end)

    :ok
  end

  # Private reconciliation functions

  defp reconcile_children(tree, parent_id, parent_fiber, context) do
    # For now, we rely on components registering themselves during render
    # In a full implementation, we'd parse the rendered output to find child components

    new_children =
      context.new_fibers
      |> Map.new(fn {id, fiber} ->
        {id, %{fiber | parent_id: parent_id, status: :stable}}
      end)

    # Remove old children that aren't in new children
    old_children = parent_fiber.children || []
    new_child_ids = Map.keys(new_children)

    tree_without_old =
      Enum.reduce(old_children, tree, fn child_id, acc ->
        if child_id not in new_child_ids do
          # Mark as unmounting
          Map.update(acc, child_id, nil, fn fiber ->
            %{fiber | status: :unmounting}
          end)
        else
          acc
        end
      end)

    # Add new children
    tree_without_old
    |> Map.merge(new_children)
    |> Map.update!(parent_id, &%{&1 | children: new_child_ids})
  end
end
