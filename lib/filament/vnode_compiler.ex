defmodule Filament.VNodeCompiler do
  @moduledoc """
  Compiles ~F template strings into %Phoenix.LiveView.Rendered{} structs with a
  trivial dynamic fn.

  KEY INVARIANT: all real work (hooks, child renders, event handler registration,
  use_memo calls) happens in the LINEAR BODY of the render function, where the
  Filament fiber context is active. The dynamic fn is TRIVIAL — it only returns
  already-bound local variables. This prevents crashes when Phoenix's diff engine
  re-invokes the dynamic fn outside the Filament render context.

  Pipeline:
    1. Filament.TagEngine.compile  → %Rendered{} AST with work inside the dynamic fn
    2. hoist_dynamics              → lifts slot exprs out; fn becomes fn _ -> [v0, v1] end
    3. transform_at_assigns        → @foo → bare var (for reactive dep detection)
    4. wrap_in_use_memo            → wraps reactive slot exprs in use_memo/2
  """

  @spec compile(String.t(), Macro.Env.t() | nil) :: term()
  def compile(source, caller) do
    quoted =
      Filament.TagEngine.compile(preprocess_jsx(source),
        file: caller.file,
        line: caller.line + 1,
        caller: caller,
        indentation: 0,
        tag_handler: Filament.HTMLEngine
      )

    hoisted = hoist_dynamics(quoted, caller)

    in_scope = MapSet.new(Map.keys(caller.versioned_vars), fn {name, _ctx} -> name end)
    {transformed, reactive_vars} = transform_at_assigns(hoisted, in_scope)

    wrap_in_use_memo(transformed, reactive_vars)
  end

  # ─── JSX preprocessor ───────────────────────────────────────────────────────

  # Transform JSX-style control flow syntax into standard EEx tags:
  #   {if cond do}…{end}      →  <%= if cond do %>…<% end %>
  #   {for x <- list do}…{end} →  <%= for x <- list do %>…<% end %>
  #   {else}, {end}, {rescue}  →  <% else %>, <% end %>, <% rescue %>
  #
  # Uses greedy `.*` so compound block conditions (like `{for {{a,b},c} <- ...`)
  # are captured correctly. Non-dotall: patterns don't cross newlines.
  defp preprocess_jsx(source) do
    source
    |> String.replace(
      ~r/\{(if|unless|for|case|cond|with|try|receive)\b(.*)\bdo\s*\}/,
      "<%= \\1\\2do %>"
    )
    |> String.replace(~r/\{(else|end|rescue|after|catch)\s*\}/, "<% \\1 %>")
  end

  # ─── Dynamic hoisting ────────────────────────────────────────────────────────

  # Walk the TagEngine AST bottom-up, finding each innermost block of the form
  # [dynamic_fn_assignment, %Rendered{} struct] and transforming it:
  #   - extract slot expressions from the fn body
  #   - emit them as linear assignments in the enclosing scope
  #   - replace the fn body with fn _ -> [v0, v1, ...] end  (trivial closure)
  defp hoist_dynamics(quoted, caller) do
    caller_ast = Macro.escape({caller.module, caller.function, caller.file, caller.line})

    # Pass 1: hoist slot expressions out of each %Rendered{} dynamic fn
    hoisted =
      Macro.postwalk(quoted, fn
        {:__block__, meta, exprs} -> maybe_hoist_block(meta, exprs, caller_ast)
        node -> node
      end)

    # Pass 2: remove any remaining Phoenix change-tracking boilerplate from the
    # outer scope. Comprehension inner fns own their `changed`/`vars_changed`
    # bindings — skip fn literals entirely so they're left intact.
    strip_outer_change_tracking(hoisted)
  end

  # Walk the AST stripping outer Phoenix change-tracking variable assignments
  # without descending into fn literals (comprehension entry fns own their bindings).
  #
  # `changed = nil` and `vars_changed = nil` assignments are KEPT (with generated:true
  # to suppress unused-variable warnings) because comprehension inner fns close over them.
  # Complex assignments (the `case assigns do` form) are stripped — they lived in the
  # dynamic fn body, which is now replaced by the trivial fn.
  defp strip_outer_change_tracking({:fn, _, _} = node), do: node

  @generated [generated: true]
  @plv Phoenix.LiveView.Engine

  defp strip_outer_change_tracking({:=, _, [{:changed, _, @plv}, nil]}),
    do: {:=, @generated, [{:changed, @generated, @plv}, nil]}

  defp strip_outer_change_tracking({:=, _, [{:changed, _, @plv}, _]}), do: nil

  defp strip_outer_change_tracking({:=, _, [{:vars_changed, _, @plv}, nil]}),
    do: {:=, @generated, [{:vars_changed, @generated, @plv}, nil]}

  defp strip_outer_change_tracking({:=, _, [{:vars_changed, _, @plv}, _]}), do: nil

  defp strip_outer_change_tracking({tag, meta, args}) when is_list(args) do
    {tag, meta, Enum.map(args, &strip_outer_change_tracking/1)}
  end

  defp strip_outer_change_tracking({a, b}),
    do: {strip_outer_change_tracking(a), strip_outer_change_tracking(b)}

  defp strip_outer_change_tracking(list) when is_list(list),
    do: Enum.map(list, &strip_outer_change_tracking/1)

  defp strip_outer_change_tracking(other), do: other

  defp maybe_hoist_block(meta, exprs, caller_ast) do
    case exprs do
      [
        {:=, _, [{:dynamic, [], Phoenix.LiveView.Engine}, fn_ast]},
        {:%, struct_meta, [{:__aliases__, alias_meta, [:Phoenix, :LiveView, :Rendered]},
                           {:%{}, map_meta, fields}]}
      ] ->
        {slot_assigns, return_list} = extract_fn_slots(fn_ast)

        trivial_fn = {:fn, [], [{:->, [], [[{:_, [], nil}], return_list]}]}

        new_fields =
          fields
          |> Keyword.put(:dynamic, trivial_fn)
          |> Keyword.put(:root, nil)
          |> Keyword.put(:caller, caller_ast)

        new_rendered =
          {:%, struct_meta,
           [{:__aliases__, alias_meta, [:Phoenix, :LiveView, :Rendered]},
            {:%{}, map_meta, new_fields}]}

        # Inject `changed = nil` so comprehension inner fns have a value to close over.
        # (`vars_changed = nil` is already present at the outer level from Phoenix's boilerplate.)
        changed_nil = {:=, [generated: true], [{:changed, [generated: true], Phoenix.LiveView.Engine}, nil]}

        {:__block__, meta, [changed_nil | slot_assigns] ++ [new_rendered]}

      _ ->
        {:__block__, meta, exprs}
    end
  end

  # Extract slot variable assignments and the return list from the Phoenix-generated
  # dynamic fn body. Phoenix emits two shapes:
  #
  # No dynamics — fn takes `_`:
  #   body = {:__block__, [], [_ = assigns, []]}
  #
  # With dynamics — fn takes `track_changes?`:
  #   body = {:__block__, _, [changed_bp, vars_bp, {:__block__, _, slot_assigns}, return_list]}
  #
  # In both cases, the last element is the return list (a literal list) and the
  # second-to-last element (if a __block__) holds the slot variable assignments.
  defp extract_fn_slots({:fn, _, [{:->, _, [_args, body]}]}) do
    case body do
      {:__block__, _, exprs} when is_list(exprs) and length(exprs) >= 2 ->
        return_list = List.last(exprs)

        if is_list(return_list) do
          slot_assigns =
            case Enum.at(exprs, -2) do
              {:__block__, _, assigns} ->
                Enum.map(assigns, fn {:=, m, [var, expr]} ->
                  {:=, m, [var, simplify_slot_expr(expr)]}
                end)

              _ ->
                []
            end

          {slot_assigns, return_list}
        else
          {[], []}
        end

      _ ->
        {[], []}
    end
  end

  defp extract_fn_slots(_), do: {[], []}

  # Phoenix wraps slot expressions in change-tracking cases. Since we always call
  # the dynamic fn with track_changes? = false, `changed` is always nil and the
  # "changed" branch always executes. Simplify all such wrappers to just EXPR.
  #
  # Pattern A: PLV.Engine.changed_assign?(changed, :key) / nested_changed_assign?(...)
  #   case PLV.Engine.*(changed, ...) do true -> EXPR; false -> nil end
  defp simplify_slot_expr(
         {:case, _,
          [
            {{:., _, [Phoenix.LiveView.Engine, _fn_name]}, _, _},
            [do: [{:->, _, [[true], expr]}, {:->, _, [[false], nil]}]]
          ]}
       ) do
    expr
  end

  # Pattern B: direct `changed` guard — case changed do %{} -> nil; _ -> EXPR end
  defp simplify_slot_expr(
         {:case, _,
          [
            {:changed, _, Phoenix.LiveView.Engine},
            [do: [{:->, _, [[{:%{}, _, []}], nil]}, {:->, _, [[_], expr]}]]
          ]}
       ) do
    expr
  end

  # Pattern C: compound condition — case (f1 or f2 or ...) do true -> EXPR; false -> nil end
  # Emitted when a slot depends on multiple assigns (Phoenix ORs the changed checks).
  defp simplify_slot_expr(
         {:case, _, [_, [do: [{:->, _, [[true], expr]}, {:->, _, [[false], nil]}]]]}
       ) do
    expr
  end

  defp simplify_slot_expr(expr), do: expr

  # ─── AST transformation ───────────────────────────────────────────────────────

  # Transform @foo AST nodes to bare variable references when foo is lexically in
  # scope at the call site.
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

  defp wrap_in_use_memo(ast, reactive_vars) do
    Macro.postwalk(ast, fn node ->
      wrap_node_if_needed(node, reactive_vars)
    end)
  end

  defp wrap_node_if_needed({:=, meta, [left, right]}, _reactive_vars) do
    {:=, meta, [left, right]}
  end

  # Wrap live_to_iodata(expr) in use_memo when the inner expr depends on reactive vars.
  defp wrap_node_if_needed(
         {{:., _, [{:__aliases__, _, [:Phoenix, :LiveView, :Engine]}, :live_to_iodata]}, _,
          [inner]} = node,
         reactive_vars
       ) do
    deps = compute_deps(inner, reactive_vars)

    if deps != [] do
      dep_vars = names_to_var_ast(deps)
      quote do: Filament.Hooks.use_memo(fn -> unquote(node) end, unquote(dep_vars))
    else
      node
    end
  end

  # Wrap the fn literal inside register_event_handler in use_memo so stable
  # closures (no reactive deps) reuse the same fn reference across renders.
  defp wrap_node_if_needed(
         {{:., call_meta, [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]},
          meta, [fn_node]},
         reactive_vars
       ) do
    case fn_node do
      {:fn, _, _} ->
        deps = compute_closure_deps(fn_node, reactive_vars)
        dep_vars = names_to_var_ast(deps)

        memoized =
          quote do: Filament.Hooks.use_memo(fn -> unquote(fn_node) end, unquote(dep_vars))

        {{:., call_meta, [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]},
         meta, [memoized]}

      _ ->
        {{:., call_meta, [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]},
         meta, [fn_node]}
    end
  end

  defp wrap_node_if_needed(node, _reactive_vars), do: node

  # ─── Dependency computation ───────────────────────────────────────────────────

  defp compute_closure_deps(ast, reactive_vars) do
    collect_variables_deep(ast)
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(reactive_vars))
    |> MapSet.to_list()
  end

  defp compute_deps(ast, reactive_vars) do
    collect_variables(ast)
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(reactive_vars))
    |> MapSet.to_list()
  end

  defp names_to_var_ast(names), do: Enum.map(names, fn name -> {name, [], nil} end)

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

  defp collect_variables_deep(ast) do
    {_, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _meta, nil} = node, acc when is_atom(name) ->
          if valid_variable_name?(name), do: {node, MapSet.put(acc, name)}, else: {node, acc}
        node, acc -> {node, acc}
      end)

    MapSet.to_list(vars)
  end

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
