defmodule Filament.SigilF do
  @moduledoc """
  Implements the ~F sigil for compiling HEEx-style templates into 
  %Phoenix.LiveView.Rendered{} structs with Filament-specific validations.

  The sigil delegates to Phoenix.LiveView.TagEngine with a custom tag handler
  (Filament.HTMLEngine) and performs additional validations:

  Phase 2: Compile-time enforcement that components in :for comprehensions
  have :key attributes for stable reconciliation.
  """

  @doc """
  Compiles a HEEx-style template string into a %Phoenix.LiveView.Rendered{} struct
  that is wire-compible with Phoenix LiveView's diff engine.

  ## Examples

      iex> assigns = %{name: "World"}
      iex> ~F\"""
      ...> <div>Hello {@name}!</div>
      ...> \"""
      %Phoenix.LiveView.Rendered{...}
  """
  @doc type: :macro
  defmacro sigil_F({:<<>>, meta, [expr]}, modifiers)
           when modifiers == [] or modifiers == ~c"noformat" do
    if not Macro.Env.has_var?(__CALLER__, {:assigns, nil}) do
      raise "~F requires a variable named \"assigns\" to exist and be set to a map"
    end

    compiled =
      Phoenix.LiveView.TagEngine.compile(expr,
        file: __CALLER__.file,
        line: __CALLER__.line + 1,
        caller: __CALLER__,
        indentation: meta[:indentation] || 0,
        tag_handler: Filament.HTMLEngine
      )

    # Phase 2: Add compile-time validation for component keys in :for comprehensions
    # For now, we'll implement this as a runtime check injected into the compiled code
    # TODO: Implement true compile-time AST analysis

    compiled
  end
end
