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

  # ─── Vnode IR memoisation pass (Phase 1.4.5) ─────────────────────────────────
  #
  # Walks the AST emitted by `Filament.VNodeEngine` looking for
  # `Filament.Hooks.register_event_handler(fn_literal)` call sites — emitted by
  # `Filament.TagEngine.transform_event_attr_for_vnode/1` for `on_*` attrs —
  # and wraps the fn argument with `Filament.Hooks.memo_at({:t, idx}, deps, fn
  # -> closure end)` so re-renders return the same fn object when the
  # closure's reactive deps haven't changed.
  #
  # Reactive-value memoisation for non-handler interpolations (`{x}` in body
  # text) is a perf win but not behavioural and isn't done here.
  @doc false
  @spec assign_memos_vnode(Macro.t(), [atom()]) :: Macro.t()
  def assign_memos_vnode(ast, in_scope) do
    {result, _counter} = walk_vnode_ast(ast, in_scope, 0)
    result
  end

  # Stop at fn literals — they're component closures and own their own scope.
  defp walk_vnode_ast({:fn, _, _} = node, _in_scope, counter), do: {node, counter}

  # `Filament.Hooks.register_event_handler(fn_literal)` — wrap the fn arg with
  # memo_at. Don't recurse into the fn body.
  defp walk_vnode_ast(
         {{:., _, [{:__aliases__, _, [:Filament, :Hooks]}, :register_event_handler]} = dot,
          call_meta, [{:fn, _, _} = fn_ast]},
         in_scope,
         counter
       ) do
    deps = compute_closure_deps(fn_ast, in_scope)
    dep_vars = names_to_var_ast(deps)

    memoised =
      quote do
        Filament.Hooks.memo_at(
          {:t, unquote(counter)},
          unquote(dep_vars),
          fn -> unquote(fn_ast) end
        )
      end

    {{dot, call_meta, [memoised]}, counter + 1}
  end

  defp walk_vnode_ast(list, in_scope, counter) when is_list(list) do
    Enum.map_reduce(list, counter, fn node, c -> walk_vnode_ast(node, in_scope, c) end)
  end

  defp walk_vnode_ast({a, b}, in_scope, counter) do
    {new_a, counter} = walk_vnode_ast(a, in_scope, counter)
    {new_b, counter} = walk_vnode_ast(b, in_scope, counter)
    {{new_a, new_b}, counter}
  end

  defp walk_vnode_ast({tag, meta, args}, in_scope, counter) when is_list(args) do
    {new_args, counter} = walk_vnode_ast(args, in_scope, counter)
    {{tag, meta, new_args}, counter}
  end

  defp walk_vnode_ast(other, _in_scope, counter), do: {other, counter}

  # ─── Dependency computation ──────────────────────────────────────────────────

  defp compute_closure_deps(ast, in_scope) do
    ast
    |> collect_variables_deep()
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(in_scope))
    |> MapSet.to_list()
  end

  defp names_to_var_ast(names), do: Enum.map(names, fn name -> {name, [], nil} end)

  defp collect_variables_deep(ast) do
    {_, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _meta, nil} = node, acc when is_atom(name) ->
          if valid_variable_name?(name), do: {node, MapSet.put(acc, name)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(vars)
  end

  defp valid_variable_name?(name) when is_atom(name) do
    name not in ~w[
      fn do end after else catch rescue and or not in when
      case cond if unless with for try receive quote unquote
      super import require use alias defmodule def defp defmacro defmacrop
      __MODULE__ __DIR__ __ENV__ __STACKTRACE__ __CALLER__
      true false nil _
    ]a
  end
end
