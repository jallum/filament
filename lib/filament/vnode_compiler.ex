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

  # Closure-stability memoisation is intentionally a no-op for now.
  #
  # The naive approach — wrapping each `register_event_handler(fn)` call with
  # `memo_at({:t, N}, deps, fn -> closure end)` — is correctness-broken for
  # closures inside `:for` comprehensions: a single compile-time slot
  # `{:t, N}` is reused for every iteration at runtime, so the cache stores
  # only the LAST iteration's closure. On re-render, every iteration's
  # cache-hit returns that one closure, and all three (or N) for-loop
  # buttons end up wired to the wrong handler.
  #
  # The legacy `assign_and_emit` avoided this by detecting comprehensions in
  # `do_walk` and wrapping the entire for-loop with a single memo (deps =
  # outer-scope vars). Porting that to vnode IR is tracked as a follow-up
  # ticket. Until then we accept the loss of closure-identity stability —
  # behaviour is correct (each render produces fresh closures with the right
  # captured vars; wire-ref slot indexing is monotonic and stable).
  @doc false
  @spec assign_memos_vnode(Macro.t(), [atom()]) :: Macro.t()
  def assign_memos_vnode(ast, _in_scope), do: ast
end
