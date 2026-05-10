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
    |> rewrite_at_assigns()
  end

  # `Phoenix.LiveView.Engine` intercepts `@foo` in `~H` templates and rewrites
  # it to `assigns[:foo]`. `VNodeEngine` bypasses PLV.Engine, so we do the
  # rewrite here on the compiled AST — bare map access via the lexical
  # `assigns` var bound by the component function head. Components that
  # destructure props in the function head don't go through this path.
  defp rewrite_at_assigns(ast) do
    Macro.postwalk(ast, fn
      {:@, _meta, [{name, _, ctx}]} when is_atom(name) and is_atom(ctx) ->
        assigns_var = Macro.var(:assigns, nil)
        quote(do: unquote(assigns_var)[unquote(name)])

      other ->
        other
    end)
  end
end
