defmodule Filament.VNodeCompiler do
  @moduledoc false

  @spec compile(String.t(), Macro.Env.t() | nil) :: term()
  def compile(source, caller) do
    source
    |> Filament.TagEngine.compile(
      file: caller.file,
      line: caller.line + 1,
      caller: caller,
      indentation: 0,
      tag_handler: Filament.HTMLEngine
    )
    |> check_attributes!(caller)
    |> Filament.TemplateCompiler.compile()
  end

  # `@foo` is the module attribute, as anywhere in Elixir, not an assign as
  # in `~H`. Filament has no assigns to track, and a template pasted from
  # HEEx fails here rather than reading an attribute it doesn't mean.
  defp check_attributes!(ast, %Macro.Env{module: module} = caller) when is_atom(module) and module != nil do
    Macro.prewalk(ast, fn
      {:@, meta, [{name, _, ctx}]} = attribute when is_atom(name) and is_atom(ctx) ->
        if Module.open?(module) and not Module.has_attribute?(module, name) do
          raise CompileError,
            file: caller.file,
            line: meta[:line] || caller.line,
            description:
              "@#{name} is a module attribute in ~F, and #{inspect(module)} has none; " <>
                "read a prop as props.#{name}"
        end

        attribute

      other ->
        other
    end)
  end

  defp check_attributes!(ast, _caller), do: ast
end
