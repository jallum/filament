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
    # Strip versioned_vars from caller to suppress TagEngine's false-positive warning about
    # accessing variables in LiveView templates. TagEngine's maybe_warn_taint/3 checks
    # Macro.Env.has_var?(caller, {name, nil}) which looks in versioned_vars.
    # Any variable defined in scope triggers this warning. Filament intentionally uses
    # lexical scoping; LiveView's __changed__ mechanism is irrelevant to Filament's
    # fiber reconciler.
    sanitized_caller = %{caller | versioned_vars: %{}}

    quoted =
      Phoenix.LiveView.TagEngine.compile(source,
        file: caller.file,
        line: caller.line + 1,
        caller: sanitized_caller,
        indentation: 0,
        tag_handler: Filament.HTMLEngine
      )

    # Transform @foo → bare variable, collecting which names were referenced via @.
    # Those names are the reactive inputs by definition — no caller inspection needed.
    {transformed, reactive_vars} = transform_at_assigns(quoted)

    # Wrap expressions in use_memo if they use reactive variables
    wrap_in_use_memo(transformed, reactive_vars)
  end

  # ─── AST transformation ───────────────────────────────────────────────────────

  # Transform @foo AST nodes to bare variable references, accumulating the names
  # of all @-referenced variables as reactive_vars.
  defp transform_at_assigns(ast) do
    {transformed, reactive_names} =
      Macro.postwalk(ast, MapSet.new(), fn
        {{:., _, [EEx.Engine, :fetch_assign!]}, meta, [_assigns, key]}, acc ->
          {{key, meta, nil}, MapSet.put(acc, key)}

        {{:., _, [{:__aliases__, _, [:EEx, :Engine]}, :fetch_assign!]}, meta, [_assigns, key]},
        acc ->
          {{key, meta, nil}, MapSet.put(acc, key)}

        {:var!, meta, [{:assigns, ctx, nil}]}, acc ->
          {{:assigns, meta, ctx}, acc}

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
      quote do
        Filament.Hooks.use_memo(fn -> unquote(node) end, unquote(deps))
      end
    else
      node
    end
  end

  # Filament.Hooks.register_event_handler(fn_node) — the fn is an event handler
  # closure. Wrap it in use_memo so stable closures (no reactive deps) produce
  # the same fn reference across renders. Closures capturing reactive vars get
  # a new fn only when those vars change.
  #
  # Targeting register_event_handler specifically (rather than all {:fn, _, _}
  # nodes) avoids accidentally memoizing TagEngine's dynamic fn wrapper.
  defp wrap_node_if_needed(
         {{:., call_meta, [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]},
          meta, [fn_node]},
         reactive_vars
       ) do
    deps = compute_closure_deps(fn_node, reactive_vars)

    memoized =
      quote do
        Filament.Hooks.use_memo(fn -> unquote(fn_node) end, unquote(deps))
      end

    {{:., call_meta, [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]},
     meta, [memoized]}
  end

  defp wrap_node_if_needed(node, _reactive_vars) do
    node
  end

  # ─── Dependency computation ───────────────────────────────────────────────────

  # Compute reactive deps of a closure body by recursing into it.
  defp compute_closure_deps(ast, reactive_vars) do
    vars = collect_variables_deep(ast)

    vars
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(reactive_vars))
    |> MapSet.to_list()
  end

  # Compute the reactive dependencies of an AST node
  defp compute_deps(ast, reactive_vars) do
    vars = collect_variables(ast)

    deps =
      vars |> MapSet.new() |> MapSet.intersection(MapSet.new(reactive_vars)) |> MapSet.to_list()

    deps
  end

  # Collect variable references from an AST node, stopping at closure boundaries.
  # Used for computing deps of non-closure expressions (do not cross into fn bodies).
  defp collect_variables(ast) do
    {_, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:fn, _, _} = node, acc -> {node, acc}
        {name, _meta, nil} = node, acc when is_atom(name) ->
          if valid_variable_name?(name), do: {node, MapSet.put(acc, name)}, else: {node, acc}
        node, acc -> {node, acc}
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
        node, acc -> {node, acc}
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
