defmodule Filament.SigilFFormatter do
  @moduledoc """
  Format `~F` templates via `mix format`.

  Add to `.formatter.exs`:

      [
        plugins: [Filament.SigilFFormatter, Styler],
        ...
      ]

  Heredoc templates (`~F\"""`) are formatted by `Phoenix.LiveView.HTMLFormatter`,
  with the same options. One-line templates are left as written, as are
  templates that use `{for}`, `{if}`, `{case}` or `{cond}` blocks and any
  with the `noformat` modifier.
  """

  @behaviour Mix.Tasks.Format

  alias Mix.Tasks.Format
  alias Phoenix.LiveView.HTMLFormatter

  @impl Format
  def features(_opts), do: [sigils: [:F]]

  @impl Format
  def format(source, opts) do
    if opts[:modifiers] == ~c"noformat" or opts[:opening_delimiter] not in [~s("""), "'''"] do
      source
    else
      HTMLFormatter.format(source, Keyword.put(opts, :sigil, :H))
    end
  rescue
    _ -> source
  end
end
