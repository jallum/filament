defmodule Filament.SigilF do
  @moduledoc """
  Implements the ~F sigil for compiling HEEx-style templates into VNode IR.

  Templates interpolate Elixir expressions with `{...}`. `@foo` reads
  `assigns[:foo]` from an `assigns` variable in scope, as in
  `def render(assigns)`.
  """

  @doc """
  Compiles a HEEx-style template string into a compiled expression.

      name = "World"
      ~F"<div>Hello {name}!</div>"

  The result is opaque: return it from `render/1`, interpolate it in another
  template, or pass it as a prop. Its shape depends on the render target —
  portable vnodes, or a compiled template under LiveView — so don't
  pattern-match it.
  """
  @doc type: :macro
  defmacro sigil_F({:<<>>, _meta, [source]}, modifiers)
           when modifiers == [] or modifiers == ~c"noformat" do
    # Use VNodeCompiler to transform the template
    # @foo becomes assigns[:foo]
    quoted = Filament.VNodeCompiler.compile(source, __CALLER__)

    # Wrap and return the quoted expression
    quote do
      unquote(quoted)
    end
  end
end
