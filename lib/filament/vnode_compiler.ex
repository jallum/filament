defmodule Filament.VNodeCompiler do
  @moduledoc false

  alias Phoenix.LiveView.Engine

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

    hoisted = hoist_dynamics(quoted, caller)

    in_scope = MapSet.new(Map.keys(caller.versioned_vars), fn {name, _ctx} -> name end)
    in_scope_list = MapSet.to_list(in_scope)
    assign_and_emit(hoisted, {in_scope_list, in_scope_list})
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
    #
    # For keyed comprehensions (:for + :key on a component tag), this pass also
    # rewrites TagEngine.component(...) calls to component_keyed(..., key) before
    # hoisting, so the child fiber is identified by key rather than position.
    hoist_comprehension_handlers(stripped)
  end

  # Walk the AST looking for comprehension entry tuples and hoist any
  # register_event_handler(fn_expr) or TagEngine.component(...) calls out of the
  # entry fn body to new variable bindings immediately before the fn. The fn
  # closes over those vars.
  #
  # PLV emits two entry-tuple shapes:
  #   {nil, var_map, entry_fn}        — non-keyed comprehensions
  #   {key_expr, var_map, entry_fn}   — keyed comprehensions (`:for` + `:key`)
  #
  # Both must be hoisted: PLV's diff engine re-calls entry fns outside the
  # Filament render context, and any hook or component call left inside an entry
  # fn body would crash there.
  #
  # Uses prewalk so that keyed for-loops (:for + :key on a component tag) are
  # visited before their bodies: when the generator carries keyed_comprehension: true
  # metadata, component(...) calls in the body are rewritten to component_keyed(...)
  # in place, so the subsequent entry-tuple hoisting picks up the keyed variant.
  defp hoist_comprehension_handlers(ast) do
    Macro.prewalk(ast, fn
      {:for, for_meta, [{:<-, gen_meta, [_lhs, _rhs]} | _rest] = args} ->
        inject_key_into_for(for_meta, gen_meta, args)

      {:{}, tuple_meta, [key, map_expr, {:fn, fn_meta, [{:->, arrow_meta, [fn_args, fn_body]}]}]} ->
        hoist_entry_tuple(tuple_meta, key, map_expr, fn_meta, arrow_meta, fn_args, fn_body)

      other ->
        other
    end)
  end

  defp inject_key_into_for(for_meta, gen_meta, args) do
    case gen_meta[:key_expr] do
      nil ->
        {:for, for_meta, args}

      key_expr ->
        new_args =
          Enum.map(args, fn
            [do: body] -> [do: rewrite_component_calls_to_keyed(body, key_expr)]
            other -> other
          end)

        {:for, for_meta, new_args}
    end
  end

  defp rewrite_component_calls_to_keyed(body, key_expr) do
    Macro.prewalk(body, fn
      {{:., dot_meta, [{:__aliases__, alias_meta, [:Filament, :TagEngine]}, :component]}, call_meta,
       [func, assigns, caller]} ->
        {{:., dot_meta, [{:__aliases__, alias_meta, [:Filament, :TagEngine]}, :component_keyed]}, call_meta,
         [func, assigns, key_expr, caller]}

      other ->
        other
    end)
  end

  defp hoist_entry_tuple(tuple_meta, key, map_expr, fn_meta, arrow_meta, fn_args, fn_body) do
    {fn_body1, reg_hoisted} = extract_reg_handlers(fn_body)
    {fn_body2, comp_hoisted} = extract_component_calls(fn_body1)
    all_hoisted = reg_hoisted ++ comp_hoisted

    if all_hoisted == [] do
      {:{}, tuple_meta, [key, map_expr, {:fn, fn_meta, [{:->, arrow_meta, [fn_args, fn_body]}]}]}
    else
      new_fn = {:fn, fn_meta, [{:->, arrow_meta, [fn_args, fn_body2]}]}
      new_tuple = {:{}, tuple_meta, [key, map_expr, new_fn]}
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
        {{:., _, [{:__aliases__, _, [:Filament, :TagEngine]}, comp_fn]}, _, _} = node, {counter, acc}
        when comp_fn in [:component, :component_keyed] ->
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

  # ─── Compile-time slot assignment ────────────────────────────────────────────

  # Single-pass walk that assigns compile-time indices to every memo and event site
  # and emits memo_at/event_at calls directly. Does NOT recurse into fn literals,
  # so only the linear render body is affected (not PLV comprehension entry fns).
  defp assign_and_emit(ast, rv) do
    {result, {_t_ctr, e_ctr}} = do_walk(ast, rv, {0, 0})
    floor_call = quote do: Filament.Hooks.set_event_handler_floor(unquote(e_ctr))
    {:__block__, [], [floor_call, result]}
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

  # ─── Vnode IR memoisation pass (Phase 1.4.5) ──────────────────────────────
  #
  # Walks the AST emitted by `Filament.VNodeEngine` looking for element vnodes
  # of the form `{:{}, _, [:element, name, attrs, children]}`. For attrs whose
  # name starts with `"on_"` and whose value is a fn literal, wraps the fn with
  # `Filament.Hooks.memo_at({:t, idx}, deps, fn -> closure end)` so re-renders
  # return the same fn object when the closure's reactive deps haven't
  # changed. Substrate walker's `resolve_event_attr` then registers the
  # memoised closure normally — wire-ref indexing is unchanged.
  #
  # Reactive-value memoisation for non-handler interpolations is a perf win
  # but not behavioural; deferred until profiling shows it's needed.
  @doc false
  @spec assign_memos_vnode(Macro.t(), [atom()]) :: Macro.t()
  def assign_memos_vnode(ast, in_scope) do
    {result, _counter} = walk_vnode_ast(ast, in_scope, 0)
    result
  end

  # Stop at fn literals — they're component closures and own their own scope.
  defp walk_vnode_ast({:fn, _, _} = node, _in_scope, counter), do: {node, counter}

  # Element vnode constructor: `{:{}, [], [:element, name, attrs, children]}`.
  # Rewrite the attrs list, then keep walking the children.
  defp walk_vnode_ast(
         {:{}, meta, [:element, name, attrs_list, children]},
         in_scope,
         counter
       ) do
    {new_attrs, counter} = walk_element_attrs(attrs_list, in_scope, counter)
    {new_children, counter} = walk_vnode_ast(children, in_scope, counter)
    {{:{}, meta, [:element, name, new_attrs, new_children]}, counter}
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

  defp walk_element_attrs(attrs_list, in_scope, counter) when is_list(attrs_list) do
    Enum.map_reduce(attrs_list, counter, fn attr, c ->
      maybe_memoise_event_attr(attr, in_scope, c)
    end)
  end

  defp walk_element_attrs(other, in_scope, counter), do: walk_vnode_ast(other, in_scope, counter)

  defp maybe_memoise_event_attr({name, {:fn, _, _} = fn_ast} = _attr, in_scope, counter)
       when is_binary(name) do
    if String.starts_with?(name, "on_") do
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

      {{name, memoised}, counter + 1}
    else
      {{name, fn_ast}, counter}
    end
  end

  defp maybe_memoise_event_attr(attr, _in_scope, counter), do: {attr, counter}

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
