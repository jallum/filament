defmodule Filament.SigilF do
  @moduledoc """
  Implements the ~F sigil for compiling HEEx-style templates into VNode IR.

  Templates interpolate Elixir expressions with `{...}`. `@foo` is the
  module attribute, as anywhere in Elixir; there are no assigns as in `~H`.
  A template that reads an attribute its module doesn't have fails to
  compile:

      @pick "pick rounded border"

      def render(%{label: label}) do
        ~F"<button class={@pick}>{label}</button>"
      end
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
    Filament.VNodeCompiler.compile(source, __CALLER__)
  end
end
