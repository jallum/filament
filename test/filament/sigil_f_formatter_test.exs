defmodule Filament.SigilFFormatterTest do
  use ExUnit.Case, async: true

  alias Filament.SigilFFormatter

  defp format(source, opts \\ []),
    do: SigilFFormatter.format(source, Keyword.merge([sigil: :F, modifiers: [], opening_delimiter: ~s(""")], opts))

  test "formats a heredoc template as HEEx does" do
    assert format(~s(<div><p   class="a">{x}</p>\n<span>hi</span></div>)) ==
             ~s(<div>\n  <p class="a">{x}</p>\n  <span>hi</span>\n</div>\n)
  end

  test "leaves one-line, block syntax and noformat templates as written" do
    assert format("<p   >{x}</p>", opening_delimiter: "|") == "<p   >{x}</p>"
    blocks = "<ul>{for x <- xs do}<li>{x}</li>{end}</ul>"
    assert format(blocks) == blocks
    assert format("<p   >{x}</p>", modifiers: ~c"noformat") == "<p   >{x}</p>"
  end
end
