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
    * `:target` - `Filament.Web` for compiled LiveView output, otherwise portable vnodes (default: `Filament.VNode`)
    * `:sources` - how `use_value/2` reads sources: `:subscribe`, `:current` (read once,
      for a static render) or `:disconnected` (default: `:subscribe`)
  """
  @spec mount(module(), map(), keyword()) ::
          {fiber_tree(), walked_vnode(), list()}
  def mount(root_component, props, opts \\ []) do
    reconcile(%{}, Fiber.new(id: "root", component: root_component), props, opts)
  end

  @doc """
  Updates the root fiber with new props and reconciles the tree.

  The root's `render/1` runs only when its props changed (`!==`) or it was
  marked dirty with `mark_dirty/2`. Otherwise its stored output is reused,
  and only dirty descendants render. The output covers the whole tree.

  Takes the same options as `mount/3`.
  """
  @spec update(fiber_tree(), String.t(), map(), keyword()) ::
          {fiber_tree(), walked_vnode(), list()}
  def update(tree, "root", new_props, opts \\ []) do
    root = Map.get(tree, "root") || raise ReconcilerError, "the tree has no root fiber"
    reconcile(tree, root, new_props, opts)
  end

  # Renders what changed, then unmounts each child that a rendered fiber no
  # longer renders. Clean subtrees stay in the tree untouched.
  defp reconcile(tree, root, props, opts) do
    context = %RenderContext{
      fiber_id: "root",
      fiber_tree: tree,
      owner_pid: Keyword.get(opts, :owner_pid),
      sources: Keyword.get(opts, :sources, :subscribe),
      target: Keyword.get(opts, :target, Filament.VNode)
    }

    {root, ctx} = Renderer.render_fiber(root, props, context)
    fibers = Map.put(ctx.new_fibers, "root", root)

    tree =
      fibers
      |> Enum.reduce(tree, fn {id, fiber}, tree -> unmount_removed(tree, Map.get(tree, id), fiber) end)
      |> Map.merge(fibers)

    {tree, target_output(root.rendered, opts), Enum.reverse(ctx.pending_effects)}
  end

  defp unmount_removed(tree, %{children: children}, %{children: children}), do: tree
  defp unmount_removed(tree, nil, _fiber), do: tree

  defp unmount_removed(tree, old, fiber) do
    kept = MapSet.new(fiber.children)
    old.children |> Enum.reject(&MapSet.member?(kept, &1)) |> Enum.reduce(tree, &unmount_fiber(&2, &1))
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
  Runs every fiber's cleanup functions and observable unsubscriptions.
  Options are accepted for symmetry with `mount/3` and ignored.
  """
  @spec unmount(fiber_tree(), keyword()) :: :ok
  def unmount(tree, _opts \\ []) do
    Enum.each(tree, fn {_id, fiber} -> HookSlot.cleanup_all(fiber.hook_slots) end)
  end

  defp target_output(output, opts) do
    case Keyword.get(opts, :target, Filament.VNode) do
      Filament.Web -> Filament.Web.to_rendered(output)
      _ -> output
    end
  end

  defp unmount_fiber(tree, fiber_id) do
    case Map.get(tree, fiber_id) do
      nil ->
        tree

      fiber ->
        HookSlot.cleanup_all(fiber.hook_slots)

        fiber.children |> Enum.reduce(tree, &unmount_fiber(&2, &1)) |> Map.delete(fiber_id)
    end
  end
end
