defmodule Filament.Reconciler do
  @moduledoc false

  alias Filament.Fiber
  alias Filament.ReconcilerError
  alias Filament.RenderContext
  alias Filament.Renderer
  alias Phoenix.LiveView.Rendered

  @type fiber_tree() :: %{String.t() => Fiber.t()}

  @doc """
  Mounts the root component and creates the initial fiber tree.

  ## Options
    * `:owner_pid` - the LiveView process that owns this render tree (default: nil)
  """
  @spec mount(module(), map(), keyword()) ::
          {fiber_tree(), Rendered.t(), list()}
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

    tree = reconcile_children(%{"root" => root_fiber}, "root", root_fiber, new_fibers, owner_pid)

    {tree, rendered, pending_effects}
  end

  @doc """
  Updates a fiber with new props and reconciles children.

  ## Options
    * `:owner_pid` - the LiveView process that owns this render tree (default: nil)
  """
  @spec update(fiber_tree(), String.t(), map(), keyword()) ::
          {fiber_tree(), Rendered.t(), list()}
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
      new_tree
      |> reconcile_children(fiber_id, updated_fiber, new_fibers, owner_pid)
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

        {index, {:subscribed, server, request, _value}} ->
          Filament.Observable.remove_projection(server, owner_pid, request, fiber.id, index)

        _ ->
          :ok
      end)

      %{fiber | status: :unmounting}
    end)

    :ok
  end

  # Private reconciliation functions

  defp reconcile_children(tree, parent_id, parent_fiber, new_fibers, owner_pid) do
    new_children =
      Map.new(new_fibers, fn {id, fiber} ->
        {id, %{fiber | parent_id: parent_id, status: :stable}}
      end)

    old_child_ids = parent_fiber.children || []
    new_child_ids = Map.keys(new_children)

    tree_after_unmount =
      Enum.reduce(old_child_ids, tree, fn child_id, acc ->
        if child_id in new_child_ids do
          acc
        else
          unmount_fiber(acc, child_id, owner_pid)
        end
      end)

    tree_after_unmount
    |> Map.merge(new_children)
    |> Map.update!(parent_id, &%{&1 | children: new_child_ids})
  end

  defp unmount_fiber(tree, fiber_id, owner_pid) do
    case Map.get(tree, fiber_id) do
      nil ->
        tree

      fiber ->
        Enum.each(fiber.hook_slots, fn
          {_index, {_deps, cleanup}} when is_function(cleanup, 0) ->
            cleanup.()

          {index, {:subscribed, server, request, _value}} ->
            Filament.Observable.remove_projection(server, owner_pid, request, fiber.id, index)

          _ ->
            :ok
        end)

        tree_without_descendants =
          Enum.reduce(fiber.children || [], tree, fn child_id, acc ->
            unmount_fiber(acc, child_id, owner_pid)
          end)

        Map.delete(tree_without_descendants, fiber_id)
    end
  end
end
