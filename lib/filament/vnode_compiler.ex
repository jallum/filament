defmodule Filament.VNodeCompiler do
  @moduledoc false

  alias Phoenix.LiveView.Engine

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

    in_scope_list = MapSet.to_list(in_scope)
    assign_and_emit(transformed, {reactive_vars, in_scope_list})
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
    stripped = strip_outer_change_tracking(hoisted)

    # Pass 3: hoist register_event_handler calls out of comprehension entry fns.
    # PLV calls those fns from its diff engine (outside our render pass), so any
    # hook call inside them crashes. Move the registrations to before the fn in
    # the for-loop body — they close over the pre-computed refs.
    hoist_comprehension_handlers(stripped)
  end

  # Walk the AST looking for comprehension entry tuples — {nil, var_map, entry_fn} —
  # and hoist any register_event_handler(fn_expr) or TagEngine.component(...) calls
  # out of the entry fn body to new variable bindings immediately before the fn.
  # The fn closes over those vars.
  #
  # This prevents PLV's diff engine from re-calling component renders or event
  # registrations outside the Filament render context (which would produce wrong
  # wire refs using the stale diff_eval_state fallback).
  defp hoist_comprehension_handlers(ast) do
    Macro.postwalk(ast, fn
      {:{}, tuple_meta, [nil, map_expr, {:fn, fn_meta, [{:->, arrow_meta, [fn_args, fn_body]}]}] = entry_parts} ->
        hoist_entry_tuple(tuple_meta, map_expr, fn_meta, arrow_meta, fn_args, fn_body, entry_parts)

      other ->
        other
    end)
  end

  defp hoist_entry_tuple(tuple_meta, map_expr, fn_meta, arrow_meta, fn_args, fn_body, entry_parts) do
    {fn_body1, reg_hoisted} = extract_reg_handlers(fn_body)
    {fn_body2, comp_hoisted} = extract_component_calls(fn_body1)
    all_hoisted = reg_hoisted ++ comp_hoisted

    if all_hoisted == [] do
      {:{}, tuple_meta, entry_parts}
    else
      new_fn = {:fn, fn_meta, [{:->, arrow_meta, [fn_args, fn_body2]}]}
      new_tuple = {:{}, tuple_meta, [nil, map_expr, new_fn]}
      assigns = Enum.map(all_hoisted, fn {var, expr} -> {:=, [], [var, expr]} end)
      {:__block__, [], assigns ++ [new_tuple]}
    end
  end

  # Replace register_event_handler(fn_expr) calls in fn_body with fresh variable refs.
  # Returns {new_fn_body, [{var_ast, original_register_expr}]}.
  defp extract_reg_handlers(fn_body) do
    base = System.unique_integer([:positive, :monotonic])

    {new_body, {_counter, hoisted}} =
      Macro.postwalk(fn_body, {base, []}, fn
        {{:., meta, [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]}, call_meta, [fn_expr]},
        {counter, acc} ->
          var_name = :"freh_#{counter}"
          var_ast = {var_name, [], nil}

          original =
            {{:., meta, [{:__aliases__, alias_meta, [:Filament, :Hooks]}, :register_event_handler]}, call_meta,
             [fn_expr]}

          {var_ast, {counter + 1, [{var_ast, original} | acc]}}

        other, acc ->
          {other, acc}
      end)

    {new_body, Enum.reverse(hoisted)}
  end

  # Replace Filament.TagEngine.component(...) calls in fn_body with fresh variable refs.
  # Returns {new_fn_body, [{var_ast, original_component_expr}]}.
  #
  # Child component renders must happen eagerly (with the Filament render context
  # active) so their wire refs are computed correctly. PLV's diff engine re-calls
  # comprehension entry fns outside the render context, so any component call left
  # inside an entry fn would produce wrong "root:0" wire refs.
  defp extract_component_calls(fn_body) do
    base = System.unique_integer([:positive, :monotonic])

    {new_body, {_counter, hoisted}} =
      Macro.postwalk(fn_body, {base, []}, fn
        {{:., _, [{:__aliases__, _, [:Filament, :TagEngine]}, :component]}, _, _} = node, {counter, acc} ->
          var_name = :"fchild_#{counter}"
          var_ast = {var_name, [], nil}
          {var_ast, {counter + 1, [{var_ast, node} | acc]}}

        other, acc ->
          {other, acc}
      end)

    {new_body, Enum.reverse(hoisted)}
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
  @plv Engine

  defp strip_outer_change_tracking({:=, _, [{:changed, _, @plv}, nil]}),
    do: {:=, @generated, [{:changed, @generated, @plv}, nil]}

  defp strip_outer_change_tracking({:=, _, [{:changed, _, @plv}, _]}), do: nil

  defp strip_outer_change_tracking({:=, _, [{:vars_changed, _, @plv}, nil]}),
    do: {:=, @generated, [{:vars_changed, @generated, @plv}, nil]}

  defp strip_outer_change_tracking({:=, _, [{:vars_changed, _, @plv}, _]}), do: nil

  defp strip_outer_change_tracking({tag, meta, args}) when is_list(args) do
    {tag, meta, Enum.map(args, &strip_outer_change_tracking/1)}
  end

  defp strip_outer_change_tracking({a, b}), do: {strip_outer_change_tracking(a), strip_outer_change_tracking(b)}

  defp strip_outer_change_tracking(list) when is_list(list), do: Enum.map(list, &strip_outer_change_tracking/1)

  defp strip_outer_change_tracking(other), do: other

  defp maybe_hoist_block(meta, exprs, caller_ast) do
    case exprs do
      [
        {:=, _, [{:dynamic, [], Engine}, fn_ast]},
        {:%, struct_meta, [{:__aliases__, alias_meta, [:Phoenix, :LiveView, :Rendered]}, {:%{}, map_meta, fields}]}
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
           [
             {:__aliases__, alias_meta, [:Phoenix, :LiveView, :Rendered]},
             {:%{}, map_meta, new_fields}
           ]}

        # Inject `changed = nil` so comprehension inner fns have a value to close over.
        # (`vars_changed = nil` is already present at the outer level from Phoenix's boilerplate.)
        changed_nil =
          {:=, [generated: true], [{:changed, [generated: true], Engine}, nil]}

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
        extract_fn_slots_from_block(exprs)

      _ ->
        {[], []}
    end
  end

  defp extract_fn_slots(_), do: {[], []}

  defp extract_fn_slots_from_block(exprs) do
    return_list = List.last(exprs)

    if is_list(return_list) do
      {extract_slot_assigns(exprs), return_list}
    else
      {[], []}
    end
  end

  defp extract_slot_assigns(exprs) do
    case Enum.at(exprs, -2) do
      {:__block__, _, assigns} ->
        Enum.map(assigns, fn {:=, m, [var, expr]} ->
          {:=, m, [var, simplify_slot_expr(expr)]}
        end)

      _ ->
        []
    end
  end

  # Phoenix wraps slot expressions in change-tracking cases. Since we always call
  # the dynamic fn with track_changes? = false, `changed` is always nil and the
  # "changed" branch always executes. Simplify all such wrappers to just EXPR.
  #
  # Pattern A: PLV.Engine.changed_assign?(changed, :key) / nested_changed_assign?(...)
  #   case PLV.Engine.*(changed, ...) do true -> EXPR; false -> nil end
  defp simplify_slot_expr(
         {:case, _, [{{:., _, [Engine, _fn_name]}, _, _}, [do: [{:->, _, [[true], expr]}, {:->, _, [[false], nil]}]]]}
       ) do
    expr
  end

  # Pattern B: direct `changed` guard — case changed do %{} -> nil; _ -> EXPR end
  defp simplify_slot_expr(
         {:case, _, [{:changed, _, Engine}, [do: [{:->, _, [[{:%{}, _, []}], nil]}, {:->, _, [[_], expr]}]]]}
       ) do
    expr
  end

  # Pattern C: compound condition — case (f1 or f2 or ...) do true -> EXPR; false -> nil end
  # Emitted when a slot depends on multiple assigns (Phoenix ORs the changed checks).
  defp simplify_slot_expr({:case, _, [_, [do: [{:->, _, [[true], expr]}, {:->, _, [[false], nil]}]]]}) do
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

  # ─── Compile-time slot assignment ────────────────────────────────────────────

  # Single-pass walk that assigns compile-time indices to every memo and event site
  # and emits memo_at/event_at calls directly. Does NOT recurse into fn literals,
  # so only the linear render body is affected (not PLV comprehension entry fns).
  defp assign_and_emit(ast, rv) do
    {result, _counters} = do_walk(ast, rv, {0, 0})
    result
  end

  defp do_walk({:fn, _, _} = node, _rv, counters), do: {node, counters}

  defp do_walk({:=, meta, [left, right]}, rv, counters) do
    {new_right, counters} = do_walk(right, rv, counters)
    {{:=, meta, [left, new_right]}, counters}
  end

  defp do_walk(list, rv, counters) when is_list(list) do
    Enum.map_reduce(list, counters, &do_walk(&1, rv, &2))
  end

  # For-loops containing register_event_handler calls are wrapped in a single
  # memo_at slot. Deps = all outer-scope vars referenced in the loop (including
  # inside fn bodies) minus loop-pattern-bound vars.  This rebuilds entry-fn
  # closures whenever any captured value changes (e.g. `current`, `filters`).
  defp do_walk({:for, meta, args} = node, rv, {t_ctr, e_ctr}) do
    if has_register_event_handler?(args) do
      dep_vars = for_loop_outer_vars(node)

      wrapped =
        quote do:
                Filament.Hooks.memo_at({:t, unquote(t_ctr)}, unquote(dep_vars), fn ->
                  unquote(node)
                end)

      {wrapped, {t_ctr + 1, e_ctr}}
    else
      {new_args, counters} = do_walk(args, rv, {t_ctr, e_ctr})
      emit_if_needed({:for, meta, new_args}, rv, counters)
    end
  end

  defp do_walk({tag, meta, args}, rv, counters) when is_list(args) do
    {new_args, counters} = do_walk(args, rv, counters)
    emit_if_needed({tag, meta, new_args}, rv, counters)
  end

  defp do_walk({a, b}, rv, counters) do
    {new_a, counters} = do_walk(a, rv, counters)
    {new_b, counters} = do_walk(b, rv, counters)
    {{new_a, new_b}, counters}
  end

  defp do_walk(other, _rv, counters), do: {other, counters}

  # live_to_iodata(expr) with reactive deps → memo_at({:t, N}, deps, factory)
  defp emit_if_needed(
         {{:., _, [{:__aliases__, _, [:Phoenix, :LiveView, :Engine]}, :live_to_iodata]}, _, [inner]} = node,
         {reactive_vars, _in_scope},
         {t_ctr, e_ctr}
       ) do
    deps = compute_deps(inner, reactive_vars)

    if deps == [] do
      {node, {t_ctr, e_ctr}}
    else
      dep_vars = names_to_var_ast(deps)

      new_node =
        quote do:
                Filament.Hooks.memo_at({:t, unquote(t_ctr)}, unquote(dep_vars), fn ->
                  unquote(node)
                end)

      {new_node, {t_ctr + 1, e_ctr}}
    end
  end

  # register_event_handler(fn) → event_at(M, memo_at({:t, N}, deps, fn -> fn end))
  defp emit_if_needed(
         {{:., _, [{:__aliases__, _, [:Filament, :Hooks]}, :register_event_handler]}, _, [fn_node]},
         {_reactive_vars, in_scope},
         {t_ctr, e_ctr}
       ) do
    case fn_node do
      {:fn, _, _} ->
        deps = compute_closure_deps(fn_node, in_scope)
        dep_vars = names_to_var_ast(deps)

        memoized =
          quote do:
                  Filament.Hooks.memo_at({:t, unquote(t_ctr)}, unquote(dep_vars), fn ->
                    unquote(fn_node)
                  end)

        wire_ref = quote do: Filament.Hooks.event_at(unquote(e_ctr), unquote(memoized))
        {wire_ref, {t_ctr + 1, e_ctr + 1}}

      _ ->
        wire_ref = quote do: Filament.Hooks.event_at(unquote(e_ctr), unquote(fn_node))
        {wire_ref, {t_ctr, e_ctr + 1}}
    end
  end

  defp emit_if_needed(node, _rv, counters), do: {node, counters}

  defp has_register_event_handler?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Filament, :Hooks]}, :register_event_handler]}, _, _} = node, _ ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # Returns outer-scope variable AST nodes to use as memo_at deps for a for-loop.
  #
  # Two kinds of deps:
  # 1. Generator collections — PLV hoists `assigns.items` to a PLV-context var like
  #    {:for, [counter: N], Phoenix.LiveView.Engine}. Extracting these directly gives
  #    us the right dep regardless of context or name (`:for` would be excluded by
  #    valid_variable_name? if we collected it as a plain var).
  # 2. Nil-context user vars referenced in the loop (excluding generator-pattern-bound
  #    and for-body-local vars). These cover outer reactive vars like `current`.
  defp for_loop_outer_vars({:for, _, args} = for_ast) do
    gen_collections =
      Enum.flat_map(args, fn
        {:<-, _, [_pattern, {name, meta, ctx}]} when is_atom(name) -> [{name, meta, ctx}]
        _ -> []
      end)

    gen_nil_names =
      Enum.reduce(args, MapSet.new(), fn
        {:<-, _, [pattern, _]}, acc -> MapSet.union(acc, collect_nil_names(pattern))
        _, acc -> acc
      end)

    body_nil_names =
      Enum.reduce(args, MapSet.new(), fn
        [do: body], acc -> MapSet.union(acc, collect_body_nil_names(body))
        _, acc -> acc
      end)

    outer_nil_vars =
      for_ast
      |> collect_nil_names()
      |> MapSet.difference(gen_nil_names)
      |> MapSet.difference(body_nil_names)
      |> Enum.map(fn name -> {name, [], nil} end)

    Enum.uniq(gen_collections ++ outer_nil_vars)
  end

  # Collect all nil-context variable names from an AST (descends into fn literals
  # to capture vars referenced by event handler closures like set_sel, on_change).
  defp collect_nil_names(ast) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _meta, nil} = node, acc when is_atom(name) ->
          if valid_variable_name?(name),
            do: {node, MapSet.put(acc, name)},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # Collect nil-context var names bound by := at the top level of a block
  # (does not descend into fn literals — those bindings are fn-local).
  defp collect_body_nil_names(ast) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:fn, _, _} = node, acc ->
          {node, acc}

        {:=, _, [{name, _, nil}, _]} = node, acc when is_atom(name) ->
          if valid_variable_name?(name),
            do: {node, MapSet.put(acc, name)},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    names
  end

  # ─── Dependency computation ───────────────────────────────────────────────────

  defp compute_closure_deps(ast, in_scope) do
    ast
    |> collect_variables_deep()
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(in_scope))
    |> MapSet.to_list()
  end

  defp compute_deps(ast, reactive_vars) do
    ast
    |> collect_variables()
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(reactive_vars))
    |> MapSet.to_list()
  end

  defp names_to_var_ast(names), do: Enum.map(names, fn name -> {name, [], nil} end)

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
      true false nil
    ]a
  end
end
