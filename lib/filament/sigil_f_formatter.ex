defmodule Filament.SigilFFormatter do
  @dialyzer :no_behaviours

  @moduledoc """
  Format `~F` templates via `mix format`.

  Add to `.formatter.exs`:

      [
        plugins: [Filament.SigilFFormatter, Styler],
        ...
      ]
  """

  @behaviour Mix.Tasks.Format

  alias Mix.Tasks.Format
  alias Phoenix.LiveView.HTMLAlgebra
  alias Phoenix.LiveView.Tokenizer
  alias Phoenix.LiveView.Tokenizer.ParseError

  require Logger

  defguard is_tag_open(tag_type)
           when tag_type in [:slot, :remote_component, :local_component, :tag]

  @inline_tags ~w(a abbr acronym audio b bdi bdo big br button canvas cite
    code data datalist del dfn em embed i iframe img input ins kbd label map
    mark meter noscript object output picture progress q ruby s samp select slot
    small span strong sub sup svg template textarea time u tt var video wbr)

  @default_line_length 98

  @impl Format
  def features(_opts) do
    [sigils: [:F]]
  end

  @impl Format
  def format(source, opts) do
    if opts[:sigil] === :F and opts[:modifiers] === ~c"noformat" do
      source
    else
      do_format(source, opts)
    end
  end

  defp do_format(source, opts) do
    line_length = opts[:f_line_length] || opts[:line_length] || @default_line_length
    newlines = :binary.matches(source, ["\r\n", "\n"])
    inline_matcher = opts[:inline_matcher] || ["link", "button"]
    opts = normalize_format_opts(opts)

    result = try_format(source, newlines, inline_matcher, opts, line_length)
    emit_format_result(result, source, opts)
  end

  defp normalize_format_opts(opts) do
    opts
    |> Keyword.put(:migrate_eex_to_curly_interpolation, true)
    |> Keyword.update(:attribute_formatters, %{}, &load_attribute_formatters/1)
  end

  defp load_attribute_formatters(formatters) do
    Enum.reduce(formatters, %{}, fn {attr, formatter}, acc ->
      if Code.ensure_loaded?(formatter) do
        Map.put(acc, to_string(attr), formatter)
      else
        Logger.error("module #{inspect(formatter)} is not loaded and could not be found")
        acc
      end
    end)
  end

  defp try_format(source, newlines, inline_matcher, opts, line_length) do
    source
    |> tokenize()
    |> to_tree([], [], %{
      source: {source, newlines},
      inline_elements: @inline_tags,
      inline_matcher: inline_matcher
    })
    |> build_formatted(opts, line_length)
  rescue
    # ~F allows {expr} block syntax (e.g. {for ... do}/{end}) that HTMLAlgebra
    # cannot format since it was designed for ~H's <%= %> block style.
    # Return source unchanged rather than corrupting it.
    _ -> :unformattable
  catch
    _, _ -> :unformattable
  end

  defp build_formatted({:ok, nodes}, opts, line_length) do
    nodes |> HTMLAlgebra.build(opts) |> Inspect.Algebra.format(line_length)
  end

  defp build_formatted({:error, line, column, message}, opts, _line_length) do
    file = Keyword.get(opts, :file, "nofile")
    raise ParseError, line: line, column: column, file: file, description: message
  end

  defp emit_format_result(:unformattable, source, _opts), do: source

  defp emit_format_result(formatted, _source, opts) do
    newline = format_trailing_newline(opts[:opening_delimiter], formatted)
    IO.iodata_to_binary([formatted, newline])
  end

  defp format_trailing_newline(delimiter, _formatted) do
    if match?(<<_>>, delimiter), do: [], else: ?\n
  end

  @eex_expr [:start_expr, :expr, :end_expr, :middle_expr]

  defp tokenize(source) do
    {:ok, eex_nodes} = EEx.tokenize(source)
    {tokens, cont} = Enum.reduce(eex_nodes, {[], {:text, :enabled}}, &do_tokenize(&1, &2, source))
    Tokenizer.finalize(tokens, "nofile", cont, source)
  end

  defp do_tokenize({:text, text, meta}, {tokens, cont}, source) do
    text = List.to_string(text)
    meta = [line: meta.line, column: meta.column]
    state = Tokenizer.init(0, "nofile", source, Phoenix.LiveView.HTMLEngine)
    Tokenizer.tokenize(text, meta, tokens, cont, state)
  end

  defp do_tokenize({:comment, text, meta}, {tokens, cont}, _source) do
    {[{:eex_comment, List.to_string(text), meta} | tokens], cont}
  end

  defp do_tokenize({type, opt, expr, %{column: column, line: line}}, {tokens, cont}, _source) when type in @eex_expr do
    meta = %{opt: opt, line: line, column: column}
    {[{:eex, type, expr |> List.to_string() |> String.trim(), meta} | tokens], cont}
  end

  defp do_tokenize(_node, acc, _source), do: acc

  defp to_tree([], buffer, [], _opts) do
    {:ok, Enum.reverse(buffer)}
  end

  defp to_tree([], _buffer, [{name, _, %{line: line, column: column}, _} | _], _opts) do
    {:error, line, column, "end of template reached without closing tag for <#{name}>"}
  end

  defp to_tree([{:text, text, %{context: [:comment_start]}} | tokens], buffer, stack, opts) do
    to_tree(tokens, [], [{:comment, text, buffer} | stack], opts)
  end

  defp to_tree(
         [{:text, text, %{context: [:comment_end | _rest]}} | tokens],
         buffer,
         [{:comment, start_text, upper_buffer} | stack],
         opts
       ) do
    buffer = Enum.reverse([{:text, String.trim_trailing(text), %{}} | buffer])
    text = {:text, String.trim_leading(start_text), %{}}
    to_tree(tokens, [{:html_comment, [text | buffer]} | upper_buffer], stack, opts)
  end

  defp to_tree([{:text, text, %{context: [:comment_start, :comment_end]}} | tokens], buffer, stack, opts) do
    meta = %{
      newlines_before_text: count_newlines_before_text(text),
      newlines_after_text: count_newlines_after_text(text)
    }

    to_tree(tokens, [{:html_comment, [{:text, String.trim(text), meta}]} | buffer], stack, opts)
  end

  defp to_tree([{:text, text, _meta} | tokens], buffer, stack, opts) do
    buffer = may_set_preserve_on_block(buffer, text)

    if line_html_comment?(text) do
      to_tree(tokens, [{:comment, text} | buffer], stack, opts)
    else
      meta = %{newlines: count_newlines_before_text(text)}
      to_tree(tokens, [{:text, text, meta} | buffer], stack, opts)
    end
  end

  defp to_tree([{:body_expr, value, meta} | tokens], buffer, stack, opts) do
    buffer = set_preserve_on_block(buffer)
    to_tree(tokens, [{:body_expr, value, meta} | buffer], stack, opts)
  end

  defp to_tree([{type, _name, attrs, %{closing: _} = meta} | tokens], buffer, stack, opts) when is_tag_open(type) do
    to_tree(tokens, [{:tag_self_close, meta.tag_name, attrs} | buffer], stack, opts)
  end

  defp to_tree([{type, _name, attrs, meta} | tokens], buffer, stack, opts) when is_tag_open(type) do
    to_tree(tokens, [], [{meta.tag_name, attrs, meta, buffer} | stack], opts)
  end

  defp to_tree(
         [{:close, _type, _name, close_meta} | tokens],
         reversed_buffer,
         [{tag_name, attrs, open_meta, upper_buffer} | stack],
         opts
       ) do
    {mode, block} =
      cond do
        tag_name in ["pre", "textarea"] or contains_special_attrs?(attrs) ->
          content =
            content_from_source(opts.source, open_meta.inner_location, close_meta.inner_location)

          {:preserve, [{:text, content, %{newlines: 0}}]}

        preceeded_by_non_white_space?(upper_buffer) ->
          {:preserve, Enum.reverse(reversed_buffer)}

        inline?(tag_name, opts.inline_elements, opts.inline_matcher) ->
          {:inline,
           reversed_buffer
           |> may_set_preserve_on_text(:last)
           |> Enum.reverse()
           |> may_set_preserve_on_text(:first)}

        true ->
          {:block, Enum.reverse(reversed_buffer)}
      end

    to_tree(tokens, [{:tag_block, tag_name, attrs, block, %{mode: mode}} | upper_buffer], stack, opts)
  end

  defp to_tree([{:eex_comment, text, _meta} | tokens], buffer, stack, opts) do
    to_tree(tokens, [{:eex_comment, text} | buffer], stack, opts)
  end

  defp to_tree([{:eex, :start_expr, expr, meta} | tokens], buffer, stack, opts) do
    to_tree(tokens, [], [{:eex_block, expr, meta, buffer} | stack], opts)
  end

  defp to_tree(
         [{:eex, :middle_expr, middle_expr, _meta} | tokens],
         buffer,
         [{:eex_block, expr, meta, upper_buffer, middle_buffer} | stack],
         opts
       ) do
    middle_buffer = [{Enum.reverse(buffer), middle_expr} | middle_buffer]
    to_tree(tokens, [], [{:eex_block, expr, meta, upper_buffer, middle_buffer} | stack], opts)
  end

  defp to_tree(
         [{:eex, :middle_expr, middle_expr, _meta} | tokens],
         buffer,
         [{:eex_block, expr, meta, upper_buffer} | stack],
         opts
       ) do
    middle_buffer = [{Enum.reverse(buffer), middle_expr}]
    to_tree(tokens, [], [{:eex_block, expr, meta, upper_buffer, middle_buffer} | stack], opts)
  end

  defp to_tree(
         [{:eex, :end_expr, end_expr, _meta} | tokens],
         buffer,
         [{:eex_block, expr, meta, upper_buffer, middle_buffer} | stack],
         opts
       ) do
    block = Enum.reverse([{Enum.reverse(buffer), end_expr} | middle_buffer])
    to_tree(tokens, [{:eex_block, expr, block, meta} | upper_buffer], stack, opts)
  end

  defp to_tree(
         [{:eex, :end_expr, end_expr, _meta} | tokens],
         buffer,
         [{:eex_block, expr, meta, upper_buffer} | stack],
         opts
       ) do
    block = [{Enum.reverse(buffer), end_expr}]
    to_tree(tokens, [{:eex_block, expr, block, meta} | upper_buffer], stack, opts)
  end

  defp to_tree([{:eex, _type, expr, meta} | tokens], buffer, stack, opts) do
    buffer = set_preserve_on_block(buffer)
    to_tree(tokens, [{:eex, expr, meta} | buffer], stack, opts)
  end

  defp inline?(tag_name, inline_elements, inline_matcher) do
    tag_name in inline_elements or Enum.any?(inline_matcher, &(tag_name =~ &1))
  end

  defp count_newlines_before_text(binary), do: count_newlines_until_text(binary, 0, 0, 1)
  defp count_newlines_after_text(binary), do: count_newlines_until_text(binary, 0, byte_size(binary) - 1, -1)

  defp count_newlines_until_text(binary, counter, pos, inc) do
    :binary.at(binary, pos)
  rescue
    _ -> counter
  else
    char when char in [?\s, ?\t] -> count_newlines_until_text(binary, counter, pos + inc, inc)
    ?\n -> count_newlines_until_text(binary, counter + 1, pos + inc, inc)
    _ -> counter
  end

  defp line_html_comment?(text) do
    trimmed = String.trim(text)
    String.starts_with?(trimmed, "<!--") and String.ends_with?(trimmed, "-->")
  end

  defp preceeded_by_non_white_space?([{:text, text, _meta} | _]),
    do: String.trim_leading(text) != "" and :binary.last(text) not in ~c"\s\t\n\r"

  defp preceeded_by_non_white_space?([{:body_expr, _, _} | _]), do: true
  defp preceeded_by_non_white_space?([{:eex, _, _} | _]), do: true
  defp preceeded_by_non_white_space?(_), do: false

  defp may_set_preserve_on_block([{:tag_block, name, attrs, block, meta} | list], text) do
    mode =
      if String.trim_leading(text) != "" and :binary.first(text) not in ~c"\s\t\n\r",
        do: :preserve,
        else: meta.mode

    [{:tag_block, name, attrs, block, %{meta | mode: mode}} | list]
  end

  defp may_set_preserve_on_block(buffer, _text), do: buffer

  defp set_preserve_on_block([{:tag_block, name, attrs, block, meta} | list]),
    do: [{:tag_block, name, attrs, block, %{meta | mode: :preserve}} | list]

  defp set_preserve_on_block(buffer), do: buffer

  defp may_set_preserve_on_text([{:text, text, meta} | buffer], where) do
    {meta, text} =
      if whitespace_around?(text, where),
        do: {Map.put(meta, :mode, :preserve), cleanup_extra_spaces(text, where)},
        else: {meta, text}

    [{:text, text, meta} | buffer]
  end

  defp may_set_preserve_on_text(buffer, _where), do: buffer

  defp whitespace_around?(text, :first), do: :binary.first(text) in ~c"\s\t" and count_newlines_before_text(text) == 0

  defp whitespace_around?(text, :last), do: :binary.last(text) in ~c"\s\t" and count_newlines_after_text(text) == 0

  defp cleanup_extra_spaces(text, :first), do: " " <> String.trim_leading(text)
  defp cleanup_extra_spaces(text, :last), do: String.trim_trailing(text) <> " "

  defp contains_special_attrs?(attrs) do
    Enum.any?(attrs, fn
      {"contenteditable", {:string, "false", _meta}, _} -> false
      {"contenteditable", _v, _} -> true
      {"phx-no-format", _v, _} -> true
      _ -> false
    end)
  end

  defp content_from_source({source, newlines}, {line_start, column_start}, {line_end, column_end}) do
    lines = Enum.slice([{0, 0} | newlines], (line_start - 1)..(line_end - 1))
    [first_line | _] = lines
    [last_line | _] = Enum.reverse(lines)
    offset_start = line_byte_offset(source, first_line, column_start)
    offset_end = line_byte_offset(source, last_line, column_end)
    binary_part(source, offset_start, offset_end - offset_start)
  end

  defp line_byte_offset(source, {line_before, line_size}, column) do
    line_offset = line_before + line_size

    line_extra =
      source
      |> binary_part(line_offset, byte_size(source) - line_offset)
      |> String.slice(0, column - 1)
      |> byte_size()

    line_offset + line_extra
  end
end
