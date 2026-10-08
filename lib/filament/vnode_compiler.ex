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
    template = {caller.module, caller.function, caller.line, :erlang.md5(source)}
    assign_and_emit(hoisted, {in_scope_list, in_scope_list}, template)
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

    # Prepare comprehension entries that need the render context as a whole.
    # Keeping their control flow intact preserves branch guards and bindings.
    prepare_comprehension_entries(stripped)
  end

  # LiveView evaluates entry functions again during diffing, outside our render
  # context. Run context-dependent entries once now and let their functions
  # return the prepared dynamics. Never extract calls from inside a branch.
  # Keyed component comprehensions also pass their key to the child renderer.
  defp prepare_comprehension_entries(ast) do
    Macro.prewalk(ast, fn
      {:for, for_meta, [{:<-, gen_meta, [_lhs, _rhs]} | _rest] = args} ->
        inject_key_into_for(for_meta, gen_meta, args)

      {:{}, tuple_meta, [key, map_expr, {:fn, fn_meta, [{:->, arrow_meta, [fn_args, fn_body]}]}]} ->
        prepare_entry_tuple(tuple_meta, key, map_expr, fn_meta, arrow_meta, fn_args, fn_body)

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

  defp prepare_entry_tuple(tuple_meta, key, map_expr, fn_meta, arrow_meta, fn_args, fn_body) do
    entry_fn = {:fn, fn_meta, [{:->, arrow_meta, [fn_args, fn_body]}]}
    tuple = {:{}, tuple_meta, [key, map_expr, entry_fn]}

    if has_render_context_call?(fn_body) do
      prepared = Macro.unique_var(:prepared_entry, __MODULE__)
      prepare = {:=, [], [prepared, quote(do: unquote(entry_fn).(%{}, false))]}
      cached_fn = {:fn, fn_meta, [{:->, arrow_meta, [fn_args, prepared]}]}
      {:__block__, [], [prepare, {:{}, tuple_meta, [key, map_expr, cached_fn]}]}
    else
      tuple
    end
  end

  defp has_render_context_call?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Filament, :Hooks]}, :register_event_handler]}, _, _} = node, _ ->
          {node, true}

        {{:., _, [{:__aliases__, _, [:Filament, :TagEngine]}, fun]}, _, _} = node, _
        when fun in [:component, :component_keyed] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
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
  defp assign_and_emit(ast, rv, template) do
    {result, {t_ctr, e_ctr}} = do_walk(ast, rv, {0, 0})

    if t_ctr == 0 and e_ctr == 0 do
      result
    else
      base = Macro.unique_var(:event_base, __MODULE__)
      scope = Macro.unique_var(:template_scope, __MODULE__)
      result = scope_template_slots(result, base, scope)

      quote do
        {unquote(base), unquote(scope)} =
          Filament.Hooks.reserve_template(unquote(Macro.escape(template)), unquote(e_ctr))

        unquote(result)
      end
    end
  end

  defp scope_template_slots(ast, base, scope) do
    Macro.postwalk(ast, fn
      {{:., _, [{:__aliases__, _, [:Filament, :Hooks]}, :event_at]} = callee, call_meta, [slot, handler]} ->
        offset = quote do: unquote(base) + unquote(slot)
        {callee, call_meta, [offset, handler]}

      {{:., _, [{:__aliases__, _, [:Filament, :Hooks]}, :memo_at]} = callee, call_meta, [{:t, slot}, deps, factory]} ->
        # A moved event range invalidates cached markup and handler replay ranges.
        key = quote do: {:t, unquote(scope), unquote(slot)}
        deps = quote do: [unquote(base) | unquote(deps)]
        {callee, call_meta, [key, deps, factory]}

      node ->
        node
    end)
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
  # 2. Nil-context user vars captured from outside the loop. These cover outer
  #    reactive vars like `current`, while respecting nested generator bindings.
  defp for_loop_outer_vars({:for, _, args} = for_ast) do
    gen_collections =
      Enum.flat_map(args, fn
        {:<-, _, [_pattern, {name, meta, ctx}]} when is_atom(name) -> [{name, meta, ctx}]
        _ -> []
      end)

    outer_nil_vars =
      for_ast
      |> dependency_ast()
      |> free_nil_names(MapSet.new())
      |> Enum.map(fn name -> {name, [], nil} end)

    Enum.uniq(gen_collections ++ outer_nil_vars)
  end

  # Gather free user variables without treating an inner generator's bindings
  # as if they were available at the enclosing memo site.
  defp free_nil_names({:for, _, args}, bound) do
    {names, _bound} =
      Enum.reduce(args, {MapSet.new(), bound}, fn
        {:<-, _, [pattern, source]}, {names, bound} ->
          names = MapSet.union(names, free_nil_names(source, bound))
          {names, MapSet.union(bound, pattern_nil_names(pattern))}

        [do: body], {names, bound} ->
          {MapSet.union(names, free_nil_names(body, bound)), bound}

        qualifier, {names, bound} ->
          {MapSet.union(names, free_nil_names(qualifier, bound)), bound}
      end)

    names
  end

  defp free_nil_names({:case, _, [subject, [do: clauses]]}, bound) do
    MapSet.union(free_nil_names(subject, bound), free_nil_names({:fn, [], clauses}, bound))
  end

  defp free_nil_names({:fn, _, clauses}, bound) do
    Enum.reduce(clauses, MapSet.new(), fn {:->, _, [patterns, body]}, names ->
      clause_bound = MapSet.union(bound, pattern_nil_names(patterns))
      MapSet.union(names, free_nil_names(body, clause_bound))
    end)
  end

  defp free_nil_names({:__block__, _, expressions}, bound) do
    {names, _bound} =
      Enum.reduce(expressions, {MapSet.new(), bound}, fn
        {:=, _, [pattern, value]}, {names, bound} ->
          names = MapSet.union(names, free_nil_names(value, bound))
          {names, MapSet.union(bound, pattern_nil_names(pattern))}

        expression, {names, bound} ->
          {MapSet.union(names, free_nil_names(expression, bound)), bound}
      end)

    names
  end

  defp free_nil_names({:=, _, [_pattern, value]}, bound), do: free_nil_names(value, bound)

  defp free_nil_names({name, _, nil}, bound) when is_atom(name) do
    if valid_variable_name?(name) and not MapSet.member?(bound, name),
      do: MapSet.new([name]),
      else: MapSet.new()
  end

  defp free_nil_names({call, _, args}, bound) when is_list(args) do
    MapSet.union(free_nil_names(call, bound), free_nil_names(args, bound))
  end

  defp free_nil_names({first, second, third}, bound) do
    first
    |> free_nil_names(bound)
    |> MapSet.union(free_nil_names(second, bound))
    |> MapSet.union(free_nil_names(third, bound))
  end

  defp free_nil_names({left, right}, bound) do
    MapSet.union(free_nil_names(left, bound), free_nil_names(right, bound))
  end

  defp free_nil_names(list, bound) when is_list(list) do
    Enum.reduce(list, MapSet.new(), &MapSet.union(&2, free_nil_names(&1, bound)))
  end

  defp free_nil_names(_, _bound), do: MapSet.new()

  defp pattern_nil_names(pattern) do
    {_, names} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {name, _, nil} = node, names when is_atom(name) ->
          if valid_variable_name?(name), do: {node, MapSet.put(names, name)}, else: {node, names}

        node, names ->
          {node, names}
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
      Macro.prewalk(dependency_ast(ast), MapSet.new(), fn
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
      Macro.prewalk(dependency_ast(ast), MapSet.new(), fn
        {name, _meta, nil} = node, acc when is_atom(name) ->
          if valid_variable_name?(name), do: {node, MapSet.put(acc, name)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(vars)
  end

  # Bitstring type names have the same AST shape as variables. Strip only the
  # specifier syntax for dependency analysis, retaining size/unit expressions.
  # The executable AST is left untouched.
  defp dependency_ast(ast) do
    Macro.prewalk(ast, fn
      {:"::", _, [value, spec]} -> [value, bitstring_spec_expressions(spec)]
      node -> node
    end)
  end

  defp bitstring_spec_expressions({:-, _, [left, right]}) do
    [bitstring_spec_expressions(left), bitstring_spec_expressions(right)]
  end

  defp bitstring_spec_expressions({name, _, args}) when name in [:size, :unit] and is_list(args), do: args

  defp bitstring_spec_expressions(_spec), do: []

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
