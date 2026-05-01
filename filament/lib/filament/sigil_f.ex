defmodule Filament.SigilF do
  @moduledoc """
  Implements the ~F sigil for compiling HEEx-style templates into 
  %Phoenix.LiveView.Rendered{} structs.

  The sigil delegates to Phoenix.LiveView.TagEngine with a custom tag handler
  (Filament.HTMLEngine) to support Filament-specific syntax and validations.
  """

  @doc """
  Compiles a HEEx-style template string into a %Phoenix.LiveView.Rendered{} struct
  that is wire-compatible with Phoenix LiveView's diff engine.

  ## Examples

      iex> assigns = %{name: "World"}
      iex> ~F"""
      ...> <div>Hello {@name}!</div>
      ...> """
      %Phoenix.LiveView.Rendered{...}
  """
  @doc type: :macro
  defmacro sigil_F({:<<>>, meta, [expr]}, modifiers)
           when modifiers == [] or modifiers == ~c"noformat" do
    if not Macro.Env.has_var?(__CALLER__, {:assigns, nil}) do
      raise "~F requires a variable named \"assigns\" to exist and be set to a map"
    end

    Phoenix.LiveView.TagEngine.compile(expr,
      file: __CALLER__.file,
      line: __CALLER__.line + 1,
      caller: __CALLER__,
      indentation: meta[:indentation] || 0,
      tag_handler: Filament.HTMLEngine
    )
  end
end
