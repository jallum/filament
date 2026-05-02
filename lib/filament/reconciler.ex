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

  ## Options
    * `:owner_pid` - the LiveView process that owns this render tree (default: nil)
  """
  @spec mount(module(), map(), keyword()) ::
          {fiber_tree(), Phoenix.LiveView.Rendered.t(), list()}
  def mount(root_component, props, opts \\ []) do
    owner_pid = Keyword.get(opts, :owner_pid)

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
      owner_pid: owner_pid,
      observable_stubs: Keyword.get(opts, :observable_stubs, %{}),
      subscribe_enabled: Keyword.get(opts, :connected, true)
    }

    # Render the component
    {rendered, new_hook_slots, pending_effects, new_fibers, new_event_handlers} =
      Renderer.render(root_component, props, context)

    # Build initial tree with root and any discovered children
    root_fiber = %{
      root_fiber
      | hook_slots: new_hook_slots,
        event_handlers: new_event_handlers,
        status: :stable
    }

    tree =
      %{"root" => root_fiber}
      |> Map.merge(new_fibers)
      |> Enum.map(fn {id, fiber} ->
        {id, %{fiber | status: :stable}}
      end)
      |> Map.new()

    {tree, rendered, pending_effects}
  end

  @doc """
  Updates a fiber with new props and reconciles children.

  ## Options
    * `:owner_pid` - the LiveView process that owns this render tree (default: nil)
  """
  @spec update(fiber_tree(), String.t(), map(), keyword()) ::
          {fiber_tree(), Phoenix.LiveView.Rendered.t(), list()}
  def update(tree, fiber_id, new_props, opts \\ []) do
    owner_pid = Keyword.get(opts, :owner_pid)

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
      owner_pid: owner_pid,
      observable_stubs: Keyword.get(opts, :observable_stubs, %{})
    }

    # Re-render component
    {rendered, new_hook_slots, pending_effects, new_fibers, new_event_handlers} =
      Renderer.render(fiber.component, new_props, context)

    # Commit hook slots and event handlers
    updated_fiber = %{
      updated_fiber
      | hook_slots: new_hook_slots,
        event_handlers: new_event_handlers
    }

    # Create new tree with updated fiber
    new_tree = Map.put(tree, fiber_id, updated_fiber)

    # Reconcile children
    final_tree =
      reconcile_children(new_tree, fiber_id, updated_fiber, new_fibers)
      |> Map.update!(fiber_id, &%{&1 | status: :stable})

    {final_tree, rendered, pending_effects}
  end

  @doc """
  Marks all fibers as unmounting and runs cleanup functions and observable unsubscriptions.

  ## Options
    * `:owner_pid` - the LiveView process that owns this render tree (default: nil)
  """
  @spec unmount(fiber_tree(), keyword()) :: :ok
  def unmount(tree, opts \\ []) do
    owner_pid = Keyword.get(opts, :owner_pid)

    tree
    |> Map.values()
    |> Enum.each(fn fiber ->
      Enum.each(fiber.hook_slots, fn
        {_index, {_deps, cleanup}} when is_function(cleanup, 0) ->
          cleanup.()

        {index, {:subscribed, server, _value}} ->
          Filament.Observable.unsubscribe(server, {owner_pid, fiber.id, index})

        {_index, {:held, server, _token}} ->
          Filament.Hold.release(server, owner_pid)

        _ ->
          :ok
      end)

      %{fiber | status: :unmounting}
    end)

    :ok
  end

  # Private reconciliation functions

  defp reconcile_children(tree, parent_id, parent_fiber, new_fibers) do
    # For now, we rely on components registering themselves during render
    # In a full implementation, we'd parse the rendered output to find child components

    new_children =
      new_fibers
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
