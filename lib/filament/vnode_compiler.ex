defmodule Filament.VNodeCompiler do
  @moduledoc false

  @spec compile(String.t(), Macro.Env.t() | nil) :: term()
  def compile(source, caller) do
    quoted =
      Filament.TagEngine.compile(source,
        file: caller.file,
        line: caller.line + 1,
        caller: caller,
        indentation: 0,
        subengine: Filament.VNodeEngine,
        tag_handler: Filament.HTMLEngine
      )

    in_scope = MapSet.new(Map.keys(caller.versioned_vars), fn {name, _ctx} -> name end)
    in_scope_list = MapSet.to_list(in_scope)

    quoted
    |> rewrite_at_assigns()
    |> assign_memos_vnode(in_scope_list)
  end

  # Phoenix.LiveView.Engine intercepts `@foo` AST in `~H` templates and rewrites
  # it to `assigns[:foo]` (with change tracking). VNodeEngine bypasses
  # PLV.Engine, so we do the rewrite here on the compiled AST. The replacement
  # uses bare map access via the lexical `assigns` var bound by the component
  # function head — components that destructure props in the function head
  # (e.g. `def render(%{count: count}) do ~F"{count}" end`) don't need this
  # path and can use the bare var instead.
  defp rewrite_at_assigns(ast) do
    Macro.postwalk(ast, fn
      {:@, _meta, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) ->
        assigns_var = Macro.var(:assigns, nil)
        quote(do: unquote(assigns_var)[unquote(name)])

      other ->
        other
    end)
  end

  # Closure-identity stability is provided by BEAM at runtime — fn closures
  # whose captures are structurally equal hash-cons to the same handle, so
  # consecutive renders of the same component shape with the same captured
  # values reuse the same fn objects across calls to `register_event_handler`.
  # That covers both single `on_*` attrs and per-iteration closures inside
  # `:for` comprehensions, with no explicit `memo_at` machinery required.
  #
  # The legacy `assign_and_emit`'s comprehension memo was an optimisation
  # that turns out to be redundant under this property. Kept here as a hook
  # for future passes (e.g. structural reactive-value memoisation) that
  # might want to walk the vnode AST.
  @doc false
  @spec assign_memos_vnode(Macro.t(), [atom()]) :: Macro.t()
  def assign_memos_vnode(ast, _in_scope), do: ast
end
