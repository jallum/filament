defmodule Filament.Reconciler do
  @moduledoc false

  alias Filament.Fiber
  alias Filament.HookSlot
  alias Filament.ReconcilerError
  alias Filament.RenderContext
  alias Filament.Renderer

  @type fiber_tree() :: %{String.t() => Fiber.t()}
  @type walked_vnode() :: term()

  @doc """
  Mounts the root component and creates the initial fiber tree.

  ## Options
    * `:owner_pid` - the LiveView process that owns this render tree (default: nil)
  """
  @spec mount(module(), map(), keyword()) ::
          {fiber_tree(), walked_vnode(), list()}
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
      subscribe_enabled: Keyword.get(opts, :connected, true)
    }

    # Render the component
    {rendered, new_hook_slots, pending_effects, new_fibers, new_event_handlers, new_capture_handlers,
     new_event_handler_kinds, new_capture_handler_kinds} =
      Renderer.render(root_component, props, context)

    # Build initial tree with root and any discovered children
    root_fiber = %{
      root_fiber
      | hook_slots: new_hook_slots,
        event_handlers: new_event_handlers,
        capture_handlers: new_capture_handlers,
        event_handler_kinds: new_event_handler_kinds,
        capture_handler_kinds: new_capture_handler_kinds,
        status: :stable,
        rendered: rendered
    }

    tree = reconcile_children(%{"root" => root_fiber}, "root", root_fiber, new_fibers, owner_pid)

    {tree, rendered, pending_effects}
  end

  @doc """
  Updates a fiber with new props and reconciles children.

  The fiber's `render/1` runs only when its props changed (`!==`) or it was
  marked dirty with `mark_dirty/2`. Otherwise its stored output is reused,
  and only dirty descendants render.

  ## Options
    * `:owner_pid` - the LiveView process that owns this render tree (default: nil)
  """
  @spec update(fiber_tree(), String.t(), map(), keyword()) ::
          {fiber_tree(), walked_vnode(), list()}
  def update(tree, fiber_id, new_props, opts \\ []) do
    owner_pid = Keyword.get(opts, :owner_pid)

    # Fetch fiber
    fiber =
      Map.get(tree, fiber_id) ||
        raise ReconcilerError, "fiber #{inspect(fiber_id)} not found in tree"

    # Create context for re-render
    context = %RenderContext{
      fiber_id: fiber_id,
      fiber_tree: tree,
      owner_pid: owner_pid
    }

    cond do
      not Renderer.reusable?(fiber, new_props) -> render_fiber(tree, fiber, new_props, context, owner_pid)
      fiber.dirty == nil -> {tree, fiber.rendered, []}
      true -> reuse_fiber(tree, fiber, context, owner_pid)
    end
  end

  defp reuse_fiber(tree, fiber, context, owner_pid) do
    {rendered, new_fibers, pending_effects} = Renderer.reuse(fiber, context)
    updated_fiber = %{fiber | rendered: rendered, dirty: nil}

    final_tree =
      tree
      |> Map.put(fiber.id, updated_fiber)
      |> reconcile_children(fiber.id, updated_fiber, new_fibers, owner_pid)

    {final_tree, rendered, pending_effects}
  end

  defp render_fiber(tree, fiber, new_props, context, owner_pid) do
    fiber_id = fiber.id
    updated_fiber = %{fiber | props: new_props, status: :updating}

    # Re-render component
    {rendered, new_hook_slots, pending_effects, new_fibers, new_event_handlers, new_capture_handlers,
     new_event_handler_kinds, new_capture_handler_kinds} =
      Renderer.render(fiber.component, new_props, context)

    # Commit hook slots and event handlers
    updated_fiber = %{
      updated_fiber
      | hook_slots: new_hook_slots,
        event_handlers: new_event_handlers,
        capture_handlers: new_capture_handlers,
        event_handler_kinds: new_event_handler_kinds,
        capture_handler_kinds: new_capture_handler_kinds,
        rendered: rendered,
        dirty: nil
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
  Mark `fiber_id` for rendering on the next `update/4`, and its ancestors as
  having a dirty descendant. Returns the tree unchanged if the fiber is gone.
  """
  @spec mark_dirty(fiber_tree(), String.t()) :: fiber_tree()
  def mark_dirty(tree, fiber_id) do
    case Map.fetch(tree, fiber_id) do
      {:ok, fiber} -> tree |> Map.put(fiber_id, %{fiber | dirty: :self}) |> mark_ancestors(fiber.parent_id)
      :error -> tree
    end
  end

  # Every dirty fiber's ancestors are already marked, so stop at the first one.
  defp mark_ancestors(tree, nil), do: tree

  defp mark_ancestors(tree, fiber_id) do
    case Map.fetch(tree, fiber_id) do
      {:ok, %{dirty: nil} = fiber} ->
        tree |> Map.put(fiber_id, %{fiber | dirty: :descendants}) |> mark_ancestors(fiber.parent_id)

      _ ->
        tree
    end
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
      HookSlot.cleanup_all(fiber.hook_slots, owner_pid, fiber.id)
      %{fiber | status: :unmounting}
    end)

    :ok
  end

  # Private reconciliation functions

  defp reconcile_children(tree, parent_id, parent_fiber, new_fibers, owner_pid) do
    new_fibers =
      new_fibers
      |> Enum.reject(fn {_id, fiber} -> fiber.status == :unmounting end)
      |> Map.new(fn {id, fiber} -> {id, %{fiber | status: :stable}} end)

    new_children = Map.filter(new_fibers, fn {_id, fiber} -> fiber.parent_id == parent_id end)

    old_child_ids = descendant_ids(tree, parent_fiber)
    new_child_ids = Map.keys(new_children)

    tree_after_unmount =
      Enum.reduce(old_child_ids, tree, fn child_id, acc ->
        if Map.has_key?(new_fibers, child_id) do
          acc
        else
          unmount_fiber(acc, child_id, owner_pid)
        end
      end)

    tree_after_unmount
    |> Map.merge(new_fibers)
    |> Map.update!(parent_id, &%{&1 | children: new_child_ids})
  end

  defp descendant_ids(tree, fiber) do
    Enum.flat_map(fiber.children || [], fn id ->
      case Map.get(tree, id) do
        nil -> []
        child -> [id | descendant_ids(tree, child)]
      end
    end)
  end

  defp unmount_fiber(tree, fiber_id, owner_pid) do
    case Map.get(tree, fiber_id) do
      nil ->
        tree

      fiber ->
        HookSlot.cleanup_all(fiber.hook_slots, owner_pid, fiber.id)

        tree_without_descendants =
          Enum.reduce(fiber.children || [], tree, fn child_id, acc ->
            unmount_fiber(acc, child_id, owner_pid)
          end)

        Map.delete(tree_without_descendants, fiber_id)
    end
  end
end
