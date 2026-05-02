defmodule Filament.VNodeCompiler do
  @moduledoc """
  Compiles ~F template strings into iodata expressions.

  Uses Phoenix.LiveView.TagEngine to parse HEEx templates with @var interpolation,
  then transforms the AST to use bare variable references instead of assigns lookups.

  Key transformations:
  1. @foo → bare variable reference (the variable foo must be in scope)
  2. Templates compile to iodata
  """

  @doc """
  Compiles a template string into a compiled template expression.

  ## Examples

      iex> assigns = %{name: "World"}
      iex> ~F"<div>Hello {@name}</div>"
      {:safe, ["<div>Hello ", "World", "</div>"]}
  """
  @spec compile(String.t(), Macro.Env.t() | nil) :: term()
  def compile(source, caller) do
    # Create a mock assigns context for compilation
    # The actual values will come from lexically-bound variables
    assigns_context =
      quote do
        var!(assigns) = %{}
      end

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
    quoted
    |> transform_at_assigns()
  end

  # Transform @foo AST nodes to bare variable references
  defp transform_at_assigns(ast) do
    Macro.postwalk(ast, &transform_node/1)
  end

  # Transform EEx.Engine.fetch_assign!(var!(assigns), :foo) to just :foo
  defp transform_node({{:., _, [EEx.Engine, :fetch_assign!]}, meta, [_assigns, key]}) do
    {key, meta, nil}
  end

  # Transform EEx.Engine.fetch_assign!(assigns, :foo) to just :foo
  defp transform_node(
         {{:., _, [{:__aliases__, _, [:EEx, :Engine]}, :fetch_assign!]}, meta, [_assigns, key]}
       ) do
    {key, meta, nil}
  end

  # Transform var!(assigns) reference - remove var!
  defp transform_node({:var!, meta, [{:assigns, ctx, nil}]}) do
    {:assigns, meta, ctx}
  end

  defp transform_node(other), do: other
end
