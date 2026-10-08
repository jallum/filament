defmodule Filament.TemplateCompiler do
  @moduledoc false

  alias Filament.Template

  def compile({:__block__, meta, expressions}) do
    {prefix, [body]} = Enum.split(expressions, -1)
    {:__block__, meta, prefix ++ [compile(body)]}
  end

  def compile(ast) do
    state = %{static: [""], bindings: [], expressions: [], count: 0, optimized?: false}
    {vnode, state} = node(ast, state)

    if state.optimized? do
      static = Enum.reverse(state.static)

      plan = %Template{
        static: static,
        bindings: Enum.reverse(state.bindings),
        fingerprint: :erlang.md5(:erlang.term_to_binary(static)),
        vnode: vnode
      }

      values = Enum.reverse(state.expressions)

      quote do
        if Filament.Template.web_target?() do
          Filament.Template.bind(unquote(Macro.escape(plan)), unquote(values))
        else
          unquote(ast)
        end
      end
    else
      ast
    end
  end

  defp node({:text, text} = vnode, state) when is_binary(text) do
    {vnode, append(%{state | optimized?: true}, text)}
  end

  defp node({:{}, _, [:element, name, attrs, children]} = ast, state)
       when is_binary(name) and is_list(attrs) and is_list(children) do
    if Enum.all?(attrs, &match?({name, _} when is_binary(name) or is_atom(name), &1)) do
      state = append(%{state | optimized?: true}, "<" <> name)
      {attrs, state} = attributes(attrs, state)
      state = append(state, ">")
      {children, state} = Enum.map_reduce(children, state, &node/2)
      state = if Filament.Web.void_element?(name), do: state, else: append(state, "</" <> name <> ">")
      {{:element, name, attrs, children}, state}
    else
      binding(ast, :child, state)
    end
  end

  defp node({:fragment, children}, state) when is_list(children) do
    {children, state} = Enum.map_reduce(children, state, &node/2)
    {{:fragment, children}, state}
  end

  defp node({:for, _, _} = expression, state), do: node({:fragment, expression}, state)

  defp node({:fragment, {:for, _, args} = expression} = ast, state) do
    case List.last(args) do
      [do: {:{}, _, [:component, _module, _props, _key]}] ->
        {value, state} = binding(expression, :components, %{state | optimized?: true})
        {{:fragment, value}, state}

      _ ->
        binding(ast, :child, state)
    end
  end

  defp node(ast, state), do: binding(ast, :child, state)

  defp attributes(attrs, state) do
    Enum.map_reduce(attrs, state, fn {name, value}, state ->
      name = to_string(name)

      if literal_attribute?(value) do
        {value, []} = Code.eval_quoted(value)
        {{name, value}, append(state, name |> Filament.Web.attribute(value) |> IO.iodata_to_binary())}
      else
        state = append(state, " " <> name <> ~s(="))
        {value, state} = binding(value, {:attribute, name}, state)
        {{name, value}, append(state, ~s("))}
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
