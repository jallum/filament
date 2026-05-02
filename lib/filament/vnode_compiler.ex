defmodule Filament.VNodeCompiler do
  @moduledoc """
  Compiles ~F template strings into iodata expressions with auto-memoization.

  Uses Phoenix.LiveView.TagEngine to parse HEEx templates with @var interpolation,
  then transforms the AST to use bare variable references instead of assigns lookups.

  Key transformations:
  1. @foo → bare variable reference (the variable foo must be in scope)
  2. Expressions using reactive variables are wrapped in use_memo/2
  3. Templates compile to iodata
  """

  @doc """
  Compiles a template string into a compiled template expression with auto-memoization.

  Reactive variables (from use_state) are detected and expressions using them
  are wrapped in use_memo/2 calls to prevent unnecessary re-evaluation.

  ## Examples

      iex> assigns = %{name: "World"}
      iex> ~F"<div>Hello {@name}</div>"
      {:safe, ["<div>Hello ", "World", "</div>"]}
  """
  @spec compile(String.t(), Macro.Env.t() | nil) :: term()
  def compile(source, caller) do
    quoted =
      Filament.TagEngine.compile(source,
        file: caller.file,
        line: caller.line + 1,
        caller: caller,
        indentation: 0,
        tag_handler: Filament.HTMLEngine
      )

    # Transform @foo → bare variable for names that are lexically in scope.
    # Only variables bound before the ~F call (e.g. from use_state) are reactive;
    # assigns-map props (@id, @title, etc.) are left as assigns.key field access.
    in_scope = MapSet.new(Map.keys(caller.versioned_vars), fn {name, _ctx} -> name end)
    {transformed, reactive_vars} = transform_at_assigns(quoted, in_scope)

    # Wrap expressions in use_memo if they use reactive variables
    wrap_in_use_memo(transformed, reactive_vars)
  end

  # ─── AST transformation ───────────────────────────────────────────────────────

  # Transform @foo AST nodes to bare variable references when foo is lexically in
  # scope at the call site. Props stored only in the assigns map are left untouched.
  defp transform_at_assigns(ast, in_scope) do
    {transformed, reactive_names} =
      Macro.postwalk(ast, MapSet.new(), fn
        {{:., _, [{:assigns, _, _}, key]}, _, _} = node, acc when is_atom(key) ->
          if MapSet.member?(in_scope, key) do
            {{key, [], nil}, MapSet.put(acc, key)}
          else
            {node, acc}
          end

        other, acc ->
          {other, acc}
      end)

    {transformed, MapSet.to_list(reactive_names)}
  end

  # ─── use_memo wrapping ───────────────────────────────────────────────────────

  # Wrap expressions in use_memo if they use reactive variables
  defp wrap_in_use_memo(ast, reactive_vars) do
    Macro.postwalk(ast, fn node ->
      wrap_node_if_needed(node, reactive_vars)
    end)
  end

  defp wrap_node_if_needed({:=, meta, [left, right]}, _reactive_vars) do
    {:=, meta, [left, right]}
  end

  # Phoenix.LiveView.Engine.live_to_iodata(expr) is the per-slot expression
  # TagEngine emits for dynamic interpolations like {@count}. Wrap it in
  # use_memo when the inner expression depends on reactive variables.
  defp wrap_node_if_needed(
         {{:., _, [{:__aliases__, _, [:Phoenix, :LiveView, :Engine]}, :live_to_iodata]}, _,
          [inner]} = node,
         reactive_vars
       ) do
    deps = compute_deps(inner, reactive_vars)

    if deps != [] do
      dep_vars = names_to_var_ast(deps)

      quote do
        Filament.Hooks.use_memo(fn -> unquote(node) end, unquote(dep_vars))
      end
    else
      node
    end
  end

  # Filament.Hooks.register_event_handler(fn_node) — the fn is an event handler
  # closure. Wrap it in use_memo only when fn_node is a lambda literal ({:fn, _,
  # _}). This allows stable closures (no reactive deps) to produce the same fn
  # reference across renders, while closures capturing reactive vars get a new fn
  # only when those vars change.
  #
  # We do NOT memoize when fn_node is an expression like assigns.on_click — the
  # assigns value may change each render and must be re-read directly.
  defp wrap_node_if_needed(
         {{:., call_meta,
           [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]}, meta,
          [fn_node]},
         reactive_vars
       ) do
    case fn_node do
      {:fn, _, _} ->
        deps = compute_closure_deps(fn_node, reactive_vars)
        dep_vars = names_to_var_ast(deps)

        memoized =
          quote do
            Filament.Hooks.use_memo(fn -> unquote(fn_node) end, unquote(dep_vars))
          end

        {{:., call_meta,
          [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]}, meta,
         [memoized]}

      _ ->
        {{:., call_meta,
          [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]}, meta,
         [fn_node]}
    end
  end

  defp wrap_node_if_needed(node, _reactive_vars) do
    node
  end

  # ─── Dependency computation ───────────────────────────────────────────────────

  # Compute reactive deps of a closure body by recursing into it.
  defp compute_closure_deps(ast, reactive_vars) do
    collect_variables_deep(ast)
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(reactive_vars))
    |> MapSet.to_list()
  end

  # Compute the reactive dependencies of an AST node
  defp compute_deps(ast, reactive_vars) do
    collect_variables(ast)
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(reactive_vars))
    |> MapSet.to_list()
  end

  # Convert a list of atom variable names to a list of variable AST nodes so
  # that unquote(dep_vars) in a quote block produces [var_a, var_b] at runtime
  # (current values) rather than [:var_a, :var_b] (literal atoms, always equal).
  defp names_to_var_ast(names), do: Enum.map(names, fn name -> {name, [], nil} end)

  # Collect variable references from an AST node, stopping at closure boundaries.
  # Used for computing deps of non-closure expressions (do not cross into fn bodies).
  defp collect_variables(ast) do
    {_, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:fn, _, _} = node, acc ->
          {node, acc}

        {name, _meta, nil} = node, acc when is_atom(name) ->
          if valid_variable_name?(name), do: {node, MapSet.put(acc, name)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(vars)
  end

  # Collect variable references from an AST node, recursing into closure bodies.
  # Used for computing what a closure captures (needed for closure dep computation).
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

  # Check if a name is a valid variable (not a reserved word or special form).
  # Source of truth: Elixir reserved words per the tokenizer.
  defp valid_variable_name?(name) when is_atom(name) do
    name not in ~w[
      fn do end after else catch rescue and or not in when
      case cond if unless with for try receive quote unquote
      super import require use alias defmodule def defp defmacro defmacrop
      __MODULE__ __DIR__ __ENV__ __STACKTRACE__ __CALLER__
      true false nil
    ]a
  end
end
