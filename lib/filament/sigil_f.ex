defmodule Filament.SigilF do
  @moduledoc """
  Implements the ~F sigil for compiling HEEx-style templates into VNode IR.

  Templates use @foo to reference lexically-scoped variables (not an assigns map).
  The template is compiled using a custom EEx engine that transforms @foo to bare
  variable references.
  """

  @doc """
  Compiles a HEEx-style template string into a compiled expression.

  ## Examples

      iex> name = "World"
      iex> ~F"<div>Hello {name}!</div>"
      "Hello World!"
  """
  @doc type: :macro
  defmacro sigil_F({:<<>>, _meta, [source]}, modifiers)
           when modifiers == [] or modifiers == ~c"noformat" do
    # Use VNodeCompiler to transform the template
    # @foo becomes bare variable reference
    quoted = Filament.VNodeCompiler.compile(source, __CALLER__)

    # Wrap and return the quoted expression
    quote do
      unquote(quoted)
    end
  end
end
