defmodule Filament.TemplateCompiler do
  @moduledoc false

  alias Filament.Template

  def compile({:__block__, meta, expressions}) do
    {prefix, [body]} = Enum.split(expressions, -1)
    {:__block__, meta, prefix ++ [compile(body)]}
  end

  def compile(ast) do
    case plan(ast) do
      {:ok, plan, values} ->
        quote do
          if Filament.Template.web_target?() do
            Filament.Template.bind(unquote(Macro.escape(plan)), unquote(values))
          else
            unquote(ast)
          end
        end

      :error ->
        ast
    end
  end

  defp plan(ast) do
    state = %{static: [""], bindings: [], expressions: [], count: 0, optimized?: false}
    {vnode, state} = node(ast, state)

    if state.optimized? do
      static = Enum.reverse(state.static)

      plan = %Template{
        static: static,
        bindings: Enum.reverse(state.bindings),
        fingerprint: :erlang.md5(:erlang.term_to_binary(static)),
        root?: Filament.Web.root?(vnode)
      }

      {:ok, plan, Enum.reverse(state.expressions)}
    else
      :error
    end
  end

  defp node({:text, text} = vnode, state) when is_binary(text) do
    {vnode, append(%{state | optimized?: true}, text)}
  end

  defp node({:{}, _, [:element, name, attrs, children]} = ast, state) when is_binary(name) and is_list(children) do
    case attribute_list(attrs) do
      {:ok, attrs} ->
        state = append(%{state | optimized?: true}, "<" <> name)
        {attrs, state} = attributes(attrs, state)
        state = append(state, ">")
        {children, state} = Enum.map_reduce(children, state, &node/2)
        state = if Filament.Web.void_element?(name), do: state, else: append(state, "</" <> name <> ">")
        {{:element, name, attrs, children}, state}

      :error ->
        binding(ast, :child, state)
    end
  end

  defp node({:fragment, children}, state) when is_list(children) do
    {children, state} = Enum.map_reduce(children, state, &node/2)
    {{:fragment, children}, state}
  end

  defp node({:for, _, _} = expression, state), do: node({:fragment, expression}, state)

  defp node({:fragment, {:for, meta, args} = expression} = ast, state) do
    {generators, [options]} = Enum.split(args, -1)

    case options do
      [do: {:{}, _, [:component, _module, _props, _key]}] ->
        {value, state} = binding(expression, :components, %{state | optimized?: true})
        {{:fragment, value}, state}

      [do: body] ->
        case row(body) do
          {:ok, row, keyed?} ->
            rows = {:for, meta, generators ++ [[do: row]]}
            {value, state} = binding(rows, {:rows, keyed?}, %{state | optimized?: true})
            {{:fragment, value}, state}

          :error ->
            binding(ast, :child, state)
        end

      _ ->
        binding(ast, :child, state)
    end
  end

  defp node(ast, state), do: binding(branches(ast), :child, state)

  # Markup in a branch of `{if}`, `{case}` or `{cond}` is a template of its own.
  defp branches({:if, meta, [condition, clauses]}) when is_list(clauses),
    do: {:if, meta, [condition, Keyword.new(clauses, fn {kind, body} -> {kind, compile(body)} end)]}

  defp branches({:case, meta, [subject, [do: clauses]]}) when is_list(clauses),
    do: {:case, meta, [subject, [do: Enum.map(clauses, &clause/1)]]}

  defp branches({:cond, meta, [[do: clauses]]}) when is_list(clauses),
    do: {:cond, meta, [[do: Enum.map(clauses, &clause/1)]]}

  defp branches(ast), do: ast

  defp clause({:->, meta, [patterns, body]}), do: {:->, meta, [patterns, compile(body)]}

  # An iteration whose body has markup of its own becomes `{key, template}`,
  # so the Web target can send the loop as a comprehension of rows.
  defp row(body) do
    {prefix, inner} =
      case body do
        {:__block__, _, expressions} -> Enum.split(expressions, -1)
        expression -> {[], [expression]}
      end

    {keys, prefix} = Enum.split_with(prefix, &match?({:=, [filament_key: true], _}, &1))

    with [inner] <- inner, {:ok, plan, values} <- plan(inner) do
      key = Enum.find_value(keys, false, fn {:=, _, [_, key]} -> key end)
      template = quote(do: Filament.Template.bind(unquote(Macro.escape(plan)), unquote(values)))
      {:ok, {:__block__, [], prefix ++ [{if(key, do: key), template}]}, key != false}
    else
      _ -> :error
    end
  end

  # VNodeEngine splices attribute groups, `on_key`'s and `{@attrs}`, in with
  # `Enum.concat/1`. Each group is one slot, as `{@rest}` is in HEEx.
  defp attribute_list({{:., _, [{:__aliases__, _, [:Enum]}, :concat]}, _, [parts]}) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      pairs when is_list(pairs) -> pairs
      group -> [{:__attr_group__, group}]
    end)
    |> attribute_list()
  end

  defp attribute_list(attrs) when is_list(attrs) do
    if Enum.all?(attrs, &match?({name, _} when is_binary(name) or is_atom(name), &1)), do: {:ok, attrs}, else: :error
  end

  defp attribute_list(_attrs), do: :error

  defp attributes(attrs, state) do
    Enum.map_reduce(attrs, state, fn
      {:__attr_group__, group}, state ->
        {value, state} = binding(group, :attributes, state)
        {{:__attr_group__, value}, state}

      {name, value}, state ->
        name = to_string(name)

        # A dynamic attribute is one slot, as in HEEx: nil, false, true and
        # keyword lists change its whole text, not just its value.
        if literal_attribute?(value) do
          {value, []} = Code.eval_quoted(value)
          {{name, value}, append(state, name |> Filament.Web.attribute(value) |> IO.iodata_to_binary())}
        else
          {value, state} = binding(value, {:attribute, name}, state)
          {{name, value}, state}
        end
    end)
  end

  defp literal_attribute?(value) when is_binary(value) or is_atom(value) or is_number(value), do: true
  defp literal_attribute?({:safe, value}) when is_binary(value), do: true
  defp literal_attribute?(value) when is_list(value), do: Enum.all?(value, &literal_attribute?/1)
  defp literal_attribute?(_), do: false

  defp append(state, ""), do: state
  defp append(%{static: [head | tail]} = state, text), do: %{state | static: [head <> text | tail]}

  defp binding(expression, kind, state) do
    index = state.count
    key = String.to_atom("binding_#{index}")

    {{:binding, index},
     %{
       state
       | static: ["" | state.static],
         bindings: [{kind, key} | state.bindings],
         expressions: [expression | state.expressions],
         count: index + 1
     }}
  end
end
