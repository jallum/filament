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
    # Use Phoenix.LiveView.TagEngine which handles @var interpolation in HEEx
    quoted =
      Phoenix.LiveView.TagEngine.compile(source,
        file: caller.file,
        line: caller.line + 1,
        caller: caller,
        indentation: 0,
        tag_handler: Filament.HTMLEngine
      )

    # Transform the AST to replace assigns[:var] with bare variable var
    transformed = transform_at_assigns(quoted)

    # Detect reactive variables from use_state patterns in the caller scope
    reactive_vars = detect_reactive_vars(caller)

    # Wrap expressions in use_memo if they use reactive variables
    wrapped = wrap_in_use_memo(transformed, reactive_vars)

    wrapped
  end

  # ─── AST transformation ───────────────────────────────────────────────────────

  # Transform @foo AST nodes to bare variable references
  defp transform_at_assigns(ast) do
    Macro.postwalk(ast, &transform_node/1)
  end

  defp transform_node({{:., _, [EEx.Engine, :fetch_assign!]}, meta, [_assigns, key]}) do
    {key, meta, nil}
  end

  defp transform_node(
         {{:., _, [{:__aliases__, _, [:EEx, :Engine]}, :fetch_assign!]}, meta, [_assigns, key]}
       ) do
    {key, meta, nil}
  end

  defp transform_node({:var!, meta, [{:assigns, ctx, nil}]}) do
    {:assigns, meta, ctx}
  end

  defp transform_node(other), do: other

  # ─── Reactive variable detection ─────────────────────────────────────────────

  # Detect reactive variables from use_state patterns in the caller scope
  # use_state returns {value, setter}, so {value, _} = use_state(_) means value is reactive
  defp detect_reactive_vars(caller) do
    caller
    |> Map.get(:bindings, [])
    |> Enum.flat_map(&detect_reactive_from_binding/1)
    |> Enum.uniq()
  end

  # Check if a binding comes from use_state pattern
  # Pattern: {reactive_var, setter_var} = use_state(...)
  defp detect_reactive_from_binding({name, {{:., _, [Hooks, :use_state]}, _, [_initial]}}) do
    # This is directly use_state(_) - no destructuring, so the whole result is reactive
    [name]
  end

  defp detect_reactive_from_binding({name, {:{}, _, [_reactive, _setter]}}) do
    # Destructured use_state: {value, setter} = use_state(...)
    # Both are potentially reactive, but setter is stable
    [name]
  end

  defp detect_reactive_from_binding(_other) do
    []
  end

  # ─── use_memo wrapping ───────────────────────────────────────────────────────

  # Wrap expressions in use_memo if they use reactive variables
  defp wrap_in_use_memo(ast, reactive_vars) do
    Macro.postwalk(ast, fn node ->
      wrap_node_if_needed(node, reactive_vars)
    end)
  end

  # Check if this is an expression that needs wrapping
  defp wrap_node_if_needed({:=, meta, [left, right]}, _reactive_vars) do
    # Skip assignment expressions
    {:=, meta, [left, right]}
  end

  defp wrap_node_if_needed({:<<>>, _meta, _parts} = node, reactive_vars) do
    # Binary concatenation - check if it contains reactive variable references
    deps = compute_deps(node, reactive_vars)

    if deps != [] do
      # Wrap in use_memo
      quote do
        Filament.Hooks.use_memo(unquote(deps), fn -> unquote(node) end)
      end
    else
      node
    end
  end

  defp wrap_node_if_needed({:fn, _, _} = node, reactive_vars) do
    # Closure - check if it captures reactive variables
    # Note: closures are typically event handlers, so we skip wrapping
    # but still compute deps for future optimization
    _deps = compute_deps(node, reactive_vars)
    node
  end

  defp wrap_node_if_needed(node, _reactive_vars) do
    node
  end

  # ─── Dependency computation ───────────────────────────────────────────────────

  # Compute the reactive dependencies of an AST node
  defp compute_deps(ast, reactive_vars) do
    vars = collect_variables(ast)

    deps =
      vars |> MapSet.new() |> MapSet.intersection(MapSet.new(reactive_vars)) |> MapSet.to_list()

    deps
  end

  # Collect all variable references from an AST node
  defp collect_variables(ast) do
    do_collect_variables(ast, [])
  end

  defp do_collect_variables({left, meta, right}, acc) when is_tuple(right) do
    acc = do_collect_variables(left, acc)
    do_collect_variables(right, acc)
  end

  defp do_collect_variables({:__block__, _meta, exprs}, acc) do
    Enum.reduce(exprs, acc, &do_collect_variables/2)
  end

  defp do_collect_variables({:fn, _, clauses}, acc) do
    # Don't recurse into closures - they're handled separately
    acc
  end

  defp do_collect_variables({name, _meta, nil}, acc) when is_atom(name) do
    # Variable reference
    if valid_variable_name?(name) do
      [name | acc]
    else
      acc
    end
  end

  defp do_collect_variables({_, _, args}, acc) when is_list(args) do
    Enum.reduce(args, acc, &do_collect_variables/2)
  end

  defp do_collect_variables({_, _, arg}, acc) do
    do_collect_variables(arg, acc)
  end

  defp do_collect_variables(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &do_collect_variables/2)
  end

  defp do_collect_variables(_, acc), do: acc

  # Check if a name is a valid variable (not a module, atom, keyword, etc.)
  defp valid_variable_name?(name) when is_atom(name) do
    # Exclude Elixir keywords and built-ins
    name not in [
      :fn,
      :do,
      :end,
      :after,
      :else,
      :catch,
      :rescue,
      :and,
      :or,
      :not,
      :in,
      :when,
      :case,
      :cond,
      :if,
      :unless,
      :try,
      :raise,
      :throw,
      :defmodule,
      :def,
      :defp,
      :defmacro,
      nil,
      true,
      false,
      :__MODULE__,
      :__DIR__,
      :__ENV__,
      :__STACKTRACE__,
      :andalso,
      :orelse,
      :inlin,
      :receive,
      :send,
      :self
    ]
  end
end
