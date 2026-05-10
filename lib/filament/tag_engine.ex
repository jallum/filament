defmodule Filament.TagEngine do
  @moduledoc false

  @behaviour EEx.Engine

  alias Phoenix.Component.MacroComponent
  alias Phoenix.LiveView.Tokenizer
  alias Phoenix.LiveView.Tokenizer.ParseError

  @doc """
  Compiles the given string into Elixir AST.

  The accepted options are:

    * `tag_handler` - Required. The module implementing the `Phoenix.LiveView.TagEngine` behavior.
    * `caller` - Required. The `Macro.Env`.
    * `line` - the starting line offset. Defaults to 1.
    * `file` - the file of the template. Defaults to `"nofile"`.
    * `indentation` - the indentation of the template. Defaults to 0.

  """
  def compile(source, options) do
    options =
      options
      |> Keyword.validate!([
        :caller,
        :tag_handler,
        line: 1,
        indentation: 0,
        file: "nofile"
      ])
      |> Keyword.merge(
        engine: Filament.TagEngine,
        source: source
      )
      |> sanitize_caller()

    EEx.compile_string(source, options)
  end

  # Strip versioned_vars so Phoenix.LiveView.Engine's taint warnings don't fire
  # for lexically-scoped variables. Filament uses lexical scoping intentionally;
  # LiveView's __changed__ change-tracking is irrelevant to Filament's fiber model.
  defp sanitize_caller(options) do
    case Keyword.fetch(options, :caller) do
      {:ok, %Macro.Env{} = caller} ->
        Keyword.put(options, :caller, %{caller | versioned_vars: %{}})

      _ ->
        options
    end
  end

  @doc """
  Classify the tag type from the given binary.

  This must return a tuple containing the type of the tag and the name of tag.
  For instance, for LiveView which uses HTML as default tag handler this would
  return `{:tag, 'div'}` in case the given binary is identified as HTML tag.

  You can also return `{:error, "reason"}` so that the compiler will display this
  error.
  """
  @callback classify_type(name :: binary()) :: {type :: atom(), name :: binary()}

  @doc """
  Returns if the given tag name is void or not.

  That's mainly useful for HTML tags and used internally by the compiler. You
  can just implement as `def void?(_), do: false` if you want to ignore this.
  """
  @callback void?(name :: binary()) :: boolean()

  @doc """
  Implements processing of attributes.

  It returns a quoted expression or attributes. If attributes are returned,
  the second element is a list where each element in the list represents
  one attribute. If the list element is a two-element tuple, it is assumed
  the key is the name to be statically written in the template. The second
  element is the value which is also statically written to the template whenever
  possible (such as binaries or binaries inside a list).
  """
  @callback handle_attributes(ast :: Macro.t(), meta :: keyword) ::
              {:attributes, [{binary(), Macro.t()} | Macro.t()]} | {:quoted, Macro.t()}

  @doc """
  Callback invoked to add annotations around the whole body of a template.
  """
  @callback annotate_body(caller :: Macro.Env.t()) :: {String.t(), String.t()} | nil

  @doc """
  Callback invoked to add caller annotations before a function component is invoked.
  """
  @callback annotate_caller(file :: String.t(), line :: integer()) :: String.t() | nil

  @impl true
  def init(opts) do
    tag_handler = Keyword.fetch!(opts, :tag_handler)

    # `Filament.VNodeEngine` is the only supported subengine. It receives
    # structured tag-open/close events from `handle_tag/3` rather than
    # HTML markup interleaved into `handle_text`.
    subengine = Filament.VNodeEngine

    %{
      cont: {:text, :enabled},
      tokens: [],
      subengine: subengine,
      substate: subengine.init(opts),
      file: Keyword.get(opts, :file, "nofile"),
      indentation: Keyword.get(opts, :indentation, 0),
      caller: Keyword.fetch!(opts, :caller),
      source: Keyword.fetch!(opts, :source),
      tag_handler: tag_handler
    }
  end

  ## These callbacks return AST

  @impl true
  def handle_body(state) do
    %{tokens: tokens, file: file, cont: cont, source: source, caller: caller} = state
    tokens = Tokenizer.finalize(tokens, file, cont, source)

    token_state =
      state
      |> token_state(nil)
      |> continue(tokens)
      |> validate_unclosed_tags!("template")

    opts = [root: token_state.root || false]

    opts =
      case caller && has_tags?(tokens) && state.tag_handler.annotate_body(caller) do
        annotation when annotation not in [false, nil] ->
          [meta: [template_annotation: annotation]] ++ opts

        _ ->
          opts
      end

    ast = invoke_subengine(token_state, :handle_body, [opts])

    quote do
      require Filament.TagEngine

      unquote(ast)
    end
  end

  defp has_tags?([{:text, _, _} | tokens]), do: has_tags?(tokens)
  defp has_tags?([{:expr, _, _} | tokens]), do: has_tags?(tokens)
  defp has_tags?([{:body_expr, _, _} | tokens]), do: has_tags?(tokens)

  # If we find a slot, discard everything in the slot and continue looking
  defp has_tags?([{:slot, _, _, _} | tokens]),
    do: tokens |> Enum.drop_while(&(not match?({:close, :slot, _, _}, &1))) |> Enum.drop(1) |> has_tags?()

  # If we find a closing tag, we missed the opening one, so we are at the end
  defp has_tags?([{:close, _, _, _} | _]), do: false
  defp has_tags?([_ | _]), do: true
  defp has_tags?([]), do: false

  defp validate_unclosed_tags!(%{tags: [tag | _]} = state, context) do
    {_type, _name, _attrs, meta} = tag
    message = "end of #{context} reached without closing tag for <#{meta.tag_name}>"
    raise_syntax_error!(message, meta, state)
  end

  defp validate_unclosed_tags!(%{stack: stack} = state, context) do
    case Enum.find(stack, &match?({:jsx_block, _, _, _}, &1)) do
      {:jsx_block, kind, _ast, meta} ->
        raise_syntax_error!(
          "end of #{context} reached without closing {end} for {#{kind}}",
          meta,
          state
        )

      nil ->
        state
    end
  end

  @impl true
  def handle_end(state) do
    state
    |> token_state(false)
    |> continue(Enum.reverse(state.tokens))
    |> validate_unclosed_tags!("do-block")
    |> invoke_subengine(:handle_end, [])
  end

  defp token_state(
         %{
           subengine: subengine,
           substate: substate,
           file: file,
           caller: caller,
           source: source,
           indentation: indentation,
           tag_handler: tag_handler
         },
         root
       ) do
    %{
      subengine: subengine,
      substate: substate,
      source: source,
      file: file,
      stack: [],
      tags: [],
      slots: [],
      caller: caller,
      root: root,
      indentation: indentation,
      tag_handler: tag_handler
    }
  end

  defp continue(token_state, tokens) do
    handle_token(tokens, token_state)
  end

  ## These callbacks update the state

  @impl true
  def handle_begin(state) do
    update_subengine(%{state | tokens: []}, :handle_begin, [])
  end

  @impl true
  def handle_text(state, meta, text) do
    %{file: file, indentation: indentation, tokens: tokens, cont: cont, source: source} = state
    tokenizer_state = Tokenizer.init(indentation, file, source, state.tag_handler)
    {tokens, cont} = Tokenizer.tokenize(text, meta, tokens, cont, tokenizer_state)

    %{
      state
      | tokens: tokens,
        cont: cont,
        source: state.source
    }
  end

  @impl true
  def handle_expr(%{tokens: tokens} = state, marker, expr) do
    %{state | tokens: [{:expr, marker, expr} | tokens]}
  end

  ## Helpers

  defp push_substate_to_stack(%{substate: substate, stack: stack} = state) do
    %{state | stack: [{:substate, substate} | stack]}
  end

  defp pop_substate_from_stack(%{stack: [{:substate, substate} | stack]} = state) do
    %{state | stack: stack, substate: substate}
  end

  defp push_stack_item(%{stack: stack} = state, item), do: %{state | stack: [item | stack]}

  defp pop_stack_item(%{stack: [_ | stack]} = state), do: %{state | stack: stack}

  defp classify_body_expr(value, _meta, opts) do
    trimmed = String.trim(value)

    cond do
      trimmed == "else" -> :jsx_else
      trimmed == "end" -> :jsx_end
      block_opener?(trimmed) -> parse_block_opener(trimmed, opts)
      true -> :expr
    end
  end

  defp block_opener?(trimmed) do
    (String.starts_with?(trimmed, "if ") or String.starts_with?(trimmed, "for ")) and
      String.ends_with?(trimmed, " do")
  end

  defp parse_block_opener(trimmed, opts) do
    case Code.string_to_quoted(trimmed <> "\nnil\nend", opts) do
      {:ok, {:if, _, [cond_ast, [do: nil]]}} ->
        {:if_block, cond_ast}

      {:ok, {:for, _, for_args}} ->
        {gen_args, _} = Enum.split(for_args, length(for_args) - 1)
        {:for_block, gen_args}

      _ ->
        :expr
    end
  end

  defp jsx_else(%{stack: [{:jsx_block, _kind, _expr, _block_meta} | _]} = state, _else_meta, tokens) do
    then_body = invoke_subengine(state, :handle_end, [])

    state
    |> push_stack_item({:jsx_else, then_body})
    |> update_subengine(:handle_begin, [])
    |> continue(tokens)
  end

  defp jsx_else(state, else_meta, _tokens) do
    raise_syntax_error!("{else} without matching {if}", else_meta, state)
  end

  defp jsx_end(%{stack: [{:jsx_else, then_body}, {:jsx_block, :if, cond_ast, _bm} | _]} = state, tokens) do
    else_body = invoke_subengine(state, :handle_end, [])

    ast =
      quote do
        if unquote(cond_ast), do: unquote(then_body), else: unquote(else_body)
      end

    state
    |> pop_stack_item()
    |> pop_stack_item()
    |> pop_substate_from_stack()
    |> set_root_on_not_tag()
    |> update_subengine(:handle_expr, ["=", ast])
    |> continue(tokens)
  end

  defp jsx_end(%{stack: [{:jsx_block, :if, cond_ast, _bm} | _]} = state, tokens) do
    body = invoke_subengine(state, :handle_end, [])

    ast =
      quote do
        if unquote(cond_ast), do: unquote(body)
      end

    state
    |> pop_stack_item()
    |> pop_substate_from_stack()
    |> set_root_on_not_tag()
    |> update_subengine(:handle_expr, ["=", ast])
    |> continue(tokens)
  end

  defp jsx_end(%{stack: [{:jsx_block, :for, for_args, _bm} | _]} = state, tokens) do
    body = invoke_subengine(state, :handle_end, [])
    for_ast = {:for, [], for_args ++ [[do: body]]}

    # The `for` expression produces a list; the surrounding vnode tree
    # expects a single child node. Wrap as `{:fragment, list}` so the
    # substrate walker descends into the iteration results in order.
    ast = {:fragment, for_ast}

    state
    |> pop_stack_item()
    |> pop_substate_from_stack()
    |> set_root_on_not_tag()
    |> update_subengine(:handle_expr, ["=", ast])
    |> continue(tokens)
  end

  defp jsx_end(_state, _tokens) do
    raise CompileError, description: "{end} without matching {if} or {for}"
  end

  defp invoke_subengine(%{subengine: subengine, substate: substate}, fun, args) do
    apply(subengine, fun, [substate | args])
  end

  defp update_subengine(state, fun, args) do
    %{state | substate: invoke_subengine(state, fun, args)}
  end

  defp maybe_prune_text_after_macro_component("", tokens), do: prune_text(tokens)
  defp maybe_prune_text_after_macro_component(_ast, tokens), do: tokens

  defp prune_text([{:text, text, meta} | tokens]), do: [{:text, String.trim_leading(text), meta} | tokens]
  defp prune_text(tokens), do: tokens

  defp push_tag(state, token) do
    %{state | tags: [token | state.tags]}
  end

  defp pop_tag!(%{tags: [{type, tag_name, _attrs, _meta} = tag | tags]} = state, {:close, type, tag_name, _}) do
    {tag, %{state | tags: tags}}
  end

  defp pop_tag!(
         %{tags: [{type, tag_open_name, _attrs, tag_open_meta} | _]} = state,
         {:close, type, tag_close_name, tag_close_meta}
       ) do
    hint = closing_void_hint(tag_close_name, state)

    message = """
    unmatched closing tag. Expected </#{tag_open_name}> for <#{tag_open_name}> \
    at line #{tag_open_meta.line}, got: </#{tag_close_name}>#{hint}\
    """

    raise_syntax_error!(message, tag_close_meta, state)
  end

  defp pop_tag!(state, {:close, _type, tag_name, tag_meta}) do
    hint = closing_void_hint(tag_name, state)
    message = "missing opening tag for </#{tag_name}>#{hint}"
    raise_syntax_error!(message, tag_meta, state)
  end

  defp closing_void_hint(tag_name, state) do
    if state.tag_handler.void?(tag_name) do
      " (note <#{tag_name}> is a void tag and cannot have any content)"
    else
      ""
    end
  end

  ## handle_token

  # Expr

  defp handle_token([{:expr, marker, expr} | tokens], state) do
    state
    |> set_root_on_not_tag()
    |> update_subengine(:handle_expr, [marker, expr])
    |> continue(tokens)
  end

  defp handle_token([{:body_expr, value, %{line: line, column: column} = meta} | tokens], state) do
    opts = [line: line, column: column, file: state.file]

    case classify_body_expr(value, meta, opts) do
      {:if_block, cond_ast} ->
        state
        |> push_substate_to_stack()
        |> push_stack_item({:jsx_block, :if, cond_ast, meta})
        |> update_subengine(:handle_begin, [])
        |> continue(tokens)

      {:for_block, for_args} ->
        state
        |> push_substate_to_stack()
        |> push_stack_item({:jsx_block, :for, for_args, meta})
        |> update_subengine(:handle_begin, [])
        |> continue(tokens)

      :jsx_else ->
        jsx_else(state, meta, tokens)

      :jsx_end ->
        jsx_end(state, tokens)

      :expr ->
        quoted = Code.string_to_quoted!(value, opts)

        state
        |> set_root_on_not_tag()
        |> update_subengine(:handle_expr, ["=", quoted])
        |> continue(tokens)
    end
  end

  # Text

  defp handle_token([{:text, text, %{line_end: line, column_end: column}} | tokens], state) do
    if text == "" do
      continue(state, tokens)
    else
      state
      |> set_root_on_not_tag()
      |> update_subengine(:handle_text, [[line: line, column: column], text])
      |> continue(tokens)
    end
  end

  # Remote function component (self close)

  defp handle_token([{:remote_component, name, attrs, %{closing: :self} = tag_meta} | tokens], state) do
    attrs = postprocess_attrs(attrs, state)
    {mod_ast, mod_size, fun} = decompose_remote_component_tag!(name, tag_meta, state)
    %{line: line, column: column} = tag_meta

    {assigns, attr_info} =
      build_self_close_component_assigns({"remote component", name}, attrs, tag_meta.line, state)

    mod = expand_with_line(mod_ast, line, state.caller)
    store_component_call({mod, fun}, attr_info, [], line, state)
    meta = [line: line, column: column + mod_size]

    case pop_special_attrs!(attrs, tag_meta, state) do
      {false, _tag_meta, _attrs} ->
        ast = build_filament_component_ast(state, mod_ast, fun, assigns, nil, tag_meta.line)

        state
        |> set_root_on_not_tag()
        |> maybe_anno_caller(meta, state.file, line)
        |> update_subengine(:handle_expr, ["=", ast])
        |> continue(tokens)

      {true, new_meta, _new_attrs} ->
        ast =
          build_self_close_component_with_special(
            state,
            new_meta,
            tag_meta,
            fn key_ast ->
              build_filament_component_ast(state, mod_ast, fun, assigns, key_ast, tag_meta.line)
            end
          )

        emit_self_close_component(state, ast, new_meta, meta, line, tokens)
    end
  end

  # Remote function component (with inner content)

  defp handle_token([{:remote_component, _name, _attrs, tag_meta} | _tokens], state) do
    raise_syntax_error!(
      "components with inner content (`<Module>...</Module>`) are not supported. " <>
        "Use a self-closing form (`<Module ... />`) and pass children as props.",
      tag_meta,
      state
    )
  end

  defp handle_token([{:slot, slot_name, _attrs, tag_meta} | _tokens], state) do
    raise_syntax_error!(
      "slot syntax `<:#{slot_name}>` is not supported. " <>
        "Pass slot content as a prop instead.",
      tag_meta,
      state
    )
  end

  # Local function component (self close)

  defp handle_token([{:local_component, name, attrs, %{closing: :self} = tag_meta} | tokens], state) do
    fun = String.to_atom(name)
    %{line: line, column: column} = tag_meta
    attrs = postprocess_attrs(attrs, state)

    {assigns, attr_info} =
      build_self_close_component_assigns({"local component", fun}, attrs, line, state)

    mod = actual_component_module(state.caller, fun)
    store_component_call({mod, fun}, attr_info, [], line, state)
    meta = [line: line, column: column]
    # `mod_ast` for local components: a literal module atom resolved from the
    # caller env (rather than an `__aliases__` AST). This is necessary because
    # the unstructured path's call AST embeds `fun` (the local function name);
    # for the structured vnode emission we want the resolved module.
    mod_ast = mod
    call = {fun, meta, __MODULE__}

    case pop_special_attrs!(attrs, tag_meta, state) do
      {false, _tag_meta, _attrs} ->
        ast = build_filament_local_component_ast(state, mod_ast, fun, call, assigns, nil, line)

        state
        |> set_root_on_not_tag()
        |> maybe_anno_caller(meta, state.file, line)
        |> update_subengine(:handle_expr, ["=", ast])
        |> continue(tokens)

      {true, new_meta, _new_attrs} ->
        ast =
          build_self_close_component_with_special(
            state,
            new_meta,
            tag_meta,
            fn key_ast ->
              build_filament_local_component_ast(state, mod_ast, fun, call, assigns, key_ast, line)
            end
          )

        emit_self_close_component(state, ast, new_meta, meta, line, tokens)
    end
  end

  # Local function component (with inner content)

  defp handle_token([{:local_component, _name, _attrs, tag_meta} | _tokens], state) do
    raise_syntax_error!(
      "components with inner content (`<Component>...</Component>`) are not supported. " <>
        "Use a self-closing form (`<Component ... />`) and pass children as props.",
      tag_meta,
      state
    )
  end

  # HTML element (self close)

  defp handle_token([{:tag, name, attrs, %{closing: closing} = tag_meta} | tokens], state) do
    suffix = if closing == :void, do: ">", else: "></#{name}>"
    attrs = postprocess_attrs(attrs, state)
    validate_phx_attrs!(attrs, tag_meta, state)
    validate_tag_attrs!(attrs, tag_meta, state)

    case pop_special_attrs!(attrs, tag_meta, state) do
      {false, tag_meta, attrs} ->
        state
        |> set_root_on_tag()
        |> handle_tag_and_attrs(name, attrs, suffix, to_location(tag_meta), true)
        |> continue(tokens)

      {true, new_meta, new_attrs} ->
        state
        |> push_substate_to_stack()
        |> update_subengine(:handle_begin, [])
        |> set_root_on_not_tag()
        |> handle_tag_and_attrs(name, new_attrs, suffix, to_location(new_meta), true)
        |> handle_special_expr(new_meta)
        |> continue(tokens)
    end
  end

  # HTML element

  defp handle_token([{:tag, name, attrs, tag_meta} = token | tokens], state) do
    attrs = postprocess_attrs(attrs, state)
    validate_phx_attrs!(attrs, tag_meta, state)
    validate_tag_attrs!(attrs, tag_meta, state)

    case List.keytake(attrs, ":type", 0) do
      {{":type", {:expr, code, _}, _meta}, attrs} ->
        # validate_phx_attrs! already ensured that if :type is present, it is an expression
        handle_macro_component([{:tag, name, attrs, tag_meta} | tokens], code, state)

      nil ->
        case pop_special_attrs!(attrs, tag_meta, state) do
          {false, tag_meta, attrs} ->
            state
            |> set_root_on_tag()
            |> push_tag(token)
            |> handle_tag_and_attrs(name, attrs, ">", to_location(tag_meta))
            |> continue(tokens)

          {true, new_meta, new_attrs} ->
            state
            |> push_substate_to_stack()
            |> update_subengine(:handle_begin, [])
            |> set_root_on_not_tag()
            |> push_tag({:tag, name, new_attrs, new_meta})
            |> handle_tag_and_attrs(name, new_attrs, ">", to_location(new_meta))
            |> continue(tokens)
        end
    end
  end

  defp handle_token([{:close, :tag, name, tag_meta} = token | tokens], state) do
    {{:tag, _name, _attrs, tag_open_meta}, state} = pop_tag!(state, token)

    state
    |> update_subengine(:handle_tag, [{:close, name}, to_location(tag_meta)])
    |> handle_special_expr(tag_open_meta)
    |> continue(tokens)
  end

  defp handle_token([], state), do: state

  defp handle_macro_component([{:tag, _name, _attrs, tag_meta} | _] = tokens, module_string, state) do
    # Macro components work by converting the HEEx tokens into an AST
    # (see Phoenix.Component.MacroComponent) and then calling the transform
    # function on the macro component module, which can return a transformed
    # AST.
    #
    # The AST is limited in functionality and we handle it separately in
    # the handle_ast function.

    (Macro.Env.required?(state.caller, Phoenix.Component) or
       Macro.Env.required?(state.caller, Filament.Component)) ||
      raise ArgumentError,
            "macro components are only supported in modules that `use Phoenix.Component` or `use Filament.Component`"

    module = validate_module!(module_string, tag_meta, state)

    try do
      {ast, rest} =
        case MacroComponent.build_ast(tokens, state.caller) do
          {:ok, ast, rest} -> {ast, rest}
          {:error, message, meta} -> raise_syntax_error!(message, meta, state)
        end

      {module.transform(ast, %{env: state.caller}), rest}
    rescue
      e in ArgumentError ->
        raise_syntax_error!(
          Exception.message(e),
          tag_meta,
          state
        )
    else
      {{:ok, new_ast}, rest} ->
        state
        |> handle_ast(new_ast, tag_meta)
        |> continue(maybe_prune_text_after_macro_component(new_ast, rest))

      {{:ok, new_ast, data}, rest} ->
        Module.put_attribute(state.caller.module, :__macro_components__, {module, data})

        state
        |> handle_ast(new_ast, tag_meta)
        |> continue(maybe_prune_text_after_macro_component(new_ast, rest))

      {other, _rest} ->
        raise ArgumentError,
              "a macro component must return {:ok, ast} or {:ok, ast, data}, got: #{inspect(other)}"
    end
  end

  # Macro components that return non-empty AST aren't supported under
  # VNodeEngine — the only macro component in our test surface is
  # `Phoenix.LiveView.ColocatedHook`, which strips the script tag and
  # returns empty AST. If a future macro component needs to emit tags or
  # text we'll add the structured emission for this path.
  defp handle_ast(state, "", _tag_open_meta), do: state
  defp handle_ast(state, [], _tag_open_meta), do: state

  defp handle_ast(state, children, tag_open_meta) when is_list(children) do
    Enum.reduce(children, state, &handle_ast(&2, &1, tag_open_meta))
  end

  defp handle_ast(_state, ast, _tag_open_meta) do
    raise ArgumentError,
          "macro component returned non-empty AST under VNodeEngine; " <>
            "only AST-stripping macro components (e.g. ColocatedHook) are supported. " <>
            "Got: #{inspect(ast)}"
  end

  defp validate_module!(module_string, tag_meta, state) do
    module =
      module_string
      |> Code.string_to_quoted!(
        file: state.file,
        line: tag_meta.line,
        column: tag_meta.column
      )
      |> Macro.expand(state.caller)

    if not is_atom(module) do
      raise_syntax_error!(
        "the given macro component #{inspect(module_string)} is not a valid module",
        tag_meta,
        state
      )
    end

    _ = Code.ensure_compiled!(module)

    if not function_exported?(module, :transform, 2) do
      raise_syntax_error!(
        "the given macro component #{inspect(module)} does not implement the `Phoenix.LiveView.MacroComponent` behaviour",
        tag_meta,
        state
      )
    end

    module
  end

  # Pop the given attr from attrs. Raises if the given attr is duplicated within
  # attrs.
  #
  # Examples:
  #
  #   attrs = [{":for", {...}}, {"class", {...}}]
  #   pop_special_attrs!(state, ":for", attrs, %{}, state)
  #   => {%{for: parsed_ast}}, {{":for", {...}}, [{"class", {...}]}}
  #
  #   attrs = [{"class", {...}}]
  #   pop_special_attrs!(state, ":for", attrs, %{}, state)
  #   => {%{}, []}
  defp pop_special_attrs!(attrs, tag_meta, state) do
    Enum.reduce([for: ":for", if: ":if", key: ":key"], {false, tag_meta, attrs}, fn
      {attr, string_attr}, {special_acc, meta_acc, attrs_acc} ->
        attrs_acc
        |> List.keytake(string_attr, 0)
        |> raise_if_duplicated_special_attr!(state)
        |> case do
          {{^string_attr, {:expr, _, _} = expr, meta}, attrs} ->
            parsed_expr = parse_expr!(expr, state.file)
            validate_quoted_special_attr!(string_attr, parsed_expr, meta, state)
            {true, Map.put(meta_acc, attr, parsed_expr), attrs}

          {{^string_attr, _expr, meta}, _attrs} ->
            message = "#{string_attr} must be an expression between {...}"
            raise_syntax_error!(message, meta, state)

          nil ->
            {special_acc, meta_acc, attrs_acc}
        end
    end)
  end

  defp raise_if_duplicated_special_attr!({{attr, _expr, _meta}, attrs} = result, state) do
    case List.keytake(attrs, attr, 0) do
      {{attr, _expr, meta}, _attrs} ->
        message =
          "cannot define multiple #{inspect(attr)} attributes. Another #{inspect(attr)} has already been defined at line #{meta.line}"

        raise_syntax_error!(message, meta, state)

      nil ->
        result
    end
  end

  defp raise_if_duplicated_special_attr!(nil, _state), do: nil

  # Root tracking
  defp set_root_on_not_tag(%{root: root, tags: tags} = state) do
    if tags == [] and root != false do
      %{state | root: false}
    else
      state
    end
  end

  defp set_root_on_tag(state) do
    case state do
      %{root: nil, tags: []} -> %{state | root: true}
      %{root: true, tags: []} -> %{state | root: false}
      %{root: bool} when is_boolean(bool) -> state
    end
  end

  ## handle_tag_and_attrs

  # `terminal?` distinguishes "no separate close coming" (void `<br>`,
  # self-closing `<br/>`) from "open tag whose close is a separate token".
  # Suffix alone can't tell us — both `<br>` and `<div>` carry `">"` — so
  # call sites pass it explicitly.
  defp handle_tag_and_attrs(state, name, attrs, _suffix, meta, terminal? \\ false) do
    structured_attrs = collect_structured_attrs(attrs, state)
    update_subengine(state, :handle_tag, [{:open, name, structured_attrs, terminal?}, meta])
  end

  # Build a `{:component, Mod, props, key}` vnode tuple constructor.
  # Filament-style components (`<Module />`) lower to `Mod.render(props)` at
  # walk time; the `<Module.fun />` Phoenix HEEx form (with a lowercase fun
  # name) isn't supported here.
  defp build_filament_component_ast(_state, mod_ast, fun, assigns, key_ast, line) do
    if fun != :render do
      raise CompileError,
        description:
          "Filament VNode emission supports `<Module />` (fun=:render) only; got #{inspect(fun)}",
        line: line
    end

    {:{}, [line: line], [:component, mod_ast, assigns, key_ast]}
  end

  defp build_filament_local_component_ast(
         _state,
         mod_ast,
         _fun,
         _call,
         assigns,
         key_ast,
         line
       ) do
    {:{}, [line: line], [:component, mod_ast, assigns, key_ast]}
  end

  # Build a self-close component AST when special attrs (`:if`, `:for`, `:key`)
  # are present. Builds the base via the caller-supplied fn, then wraps with
  # `:for` and/or `:if` if requested.
  defp build_self_close_component_with_special(_state, new_meta, _tag_meta, base_ast_fn) do
    key_ast = Map.get(new_meta, :key, nil)

    base_ast_fn.(key_ast)
    |> maybe_wrap_for(new_meta)
    |> maybe_wrap_if(new_meta)
  end

  defp maybe_wrap_for(ast, %{for: for_expr}), do: wrap_for_with_fragment(ast, for_expr)
  defp maybe_wrap_for(ast, _meta), do: ast

  defp maybe_wrap_if(ast, %{if: if_expr}), do: quote(do: if(unquote(if_expr), do: unquote(ast)))
  defp maybe_wrap_if(ast, _meta), do: ast

  defp emit_self_close_component(state, ast, _new_meta, meta, line, tokens) do
    state
    |> set_root_on_not_tag()
    |> maybe_anno_caller(meta, state.file, line)
    |> update_subengine(:handle_expr, ["=", ast])
    |> continue(tokens)
  end

  # Wrap a single component vnode AST in `for ..., do: vnode_ast` and then in
  # `{:fragment, list}` so the surrounding vnode tree treats the iteration
  # output as a flat sequence of children. When `:key` is also present, the
  # component AST already carries the key expression — the loop variable is
  # captured by the closure.
  defp wrap_for_with_fragment(component_ast, for_expr) do
    # for_expr is the parsed `:<-` AST; PLV's `for` form expects a list of
    # generator/filter clauses, so wrap it as a single-element list.
    for_ast = {:for, [], [for_expr, [do: component_ast]]}
    {:fragment, for_ast}
  end

  defp collect_structured_attrs(attrs, state) do
    attrs
    |> Enum.flat_map(fn
      {:root, {:expr, _, _} = expr, _attr_meta} ->
        [{:__root__, parse_expr!(expr, state.file)}]

      {name, {:expr, _, _} = expr, _attr_meta} ->
        [{name, parse_expr!(expr, state.file)}]

      {name, {:string, value, _meta}, _attr_meta} ->
        [{name, value}]

      {name, nil, _attr_meta} ->
        [{name, nil}]
    end)
    |> Enum.flat_map(&transform_event_attr_for_vnode/1)
  end

  # Compile-time `on_*` → `phx-*` + `register_event_handler` rewrite for the
  # vnode codegen path. Mirrors `Filament.HTMLEngine.transform_event_pair/1`'s
  # logic so VNodeEngine-emitted attrs match the wire format the LiveView
  # adapter dispatches through. Closure memoisation (Phase 1.4.5) then
  # detects the `register_event_handler(fn)` call sites and wraps them with
  # `memo_at` for stable closures across renders.
  defp transform_event_attr_for_vnode({"on_key", v}) do
    wrapped =
      quote do
        fn params ->
          mods = %Filament.KeyModifiers{
            ctrl: params["ctrl"] || false,
            shift: params["shift"] || false,
            alt: params["alt"] || false,
            meta: params["meta"] || false
          }

          unquote(v).(params["key"], mods)
        end
      end

    # `on_key` expands into THREE attrs (`phx-hook`, `data-filament-wire`,
    # `id`) that all need to share the same wire-ref string. Each attr in the
    # vnode's attrs list compiles to an independent expression context, so a
    # `wire_var = ...` binding in one attr's value isn't visible from the
    # next. Emit them as a single `:__attr_group__` whose AST evaluates to a
    # list of attr pairs — VNodeEngine flattens these back into the attrs
    # list at element-build time.
    # Match legacy HTMLEngine convention: `data-filament-wire` carries the
    # raw `fiber_id:slot` ref without the `filament:` prefix. The Filament
    # JS hook on the client side prepends it before calling pushEvent;
    # `Filament.Test.key_down/2` does the same. The `id` attr is the same
    # raw ref so the hook and element id stay aligned.
    group_ast =
      quote do
        wire = Filament.Hooks.register_event_handler(unquote(wrapped))

        [
          {"phx-hook", "FilamentKey"},
          {"data-filament-wire", wire},
          {"id", wire}
        ]
      end

    [{:__attr_group__, group_ast}]
  end

  defp transform_event_attr_for_vnode({"on_" <> event, v}) do
    [
      {"phx-" <> event,
       quote(do: "filament:" <> Filament.Hooks.register_event_handler(unquote(v)))}
    ]
  end

  defp transform_event_attr_for_vnode(pair), do: [pair]

  defp parse_expr!({:expr, value, %{line: line, column: col}}, file) do
    Code.string_to_quoted!(value, line: line, column: col, file: file)
  end

  defp handle_special_expr(state, tag_meta) do
    case build_special_expr_ast(state, tag_meta) do
      nil ->
        state

      ast ->
        state
        |> pop_substate_from_stack()
        |> update_subengine(:handle_expr, ["=", ast])
    end
  end

  defp build_special_expr_ast(state, %{for: _for_expr, if: if_expr} = tag_meta) do
    for_expr = maybe_keyed(tag_meta)

    for_ast =
      quote do
        for unquote(for_expr), unquote(if_expr), do: unquote(invoke_subengine(state, :handle_end, []))
      end

    {:fragment, for_ast}
  end

  defp build_special_expr_ast(state, %{for: _for_expr} = tag_meta) do
    for_expr = maybe_keyed(tag_meta)

    for_ast =
      quote do
        for unquote(for_expr), do: unquote(invoke_subengine(state, :handle_end, []))
      end

    {:fragment, for_ast}
  end

  defp build_special_expr_ast(state, %{if: if_expr}) do
    quote do
      if unquote(if_expr), do: unquote(invoke_subengine(state, :handle_end, []))
    end
  end

  defp build_special_expr_ast(state, %{key: _} = tag_meta) do
    raise_syntax_error!("cannot use :key without :for", tag_meta, state)
  end

  defp build_special_expr_ast(_state, %{}), do: nil

  defp maybe_keyed(%{key: key_expr, for: for_expr}) do
    # we already validated that the for expression has the correct shape in
    # validate_quoted_special_attr
    {:<-, for_meta, [lhs, rhs]} = for_expr
    {:<-, [keyed_comprehension: true, key_expr: key_expr] ++ for_meta, [lhs, rhs]}
  end

  defp maybe_keyed(%{for: for_expr}), do: for_expr

  ## build_self_close_component_assigns/build_component_assigns

  defp build_self_close_component_assigns(type_component, attrs, line, state) do
    {special, roots, attrs, attr_info} = split_component_attrs(type_component, attrs, state)
    raise_if_let!(special[":let"], state.file)
    {merge_component_attrs(roots, attrs, line), attr_info}
  end

  defp split_component_attrs(type_component, attrs, state) do
    {special, roots, attrs, locs} =
      attrs
      |> Enum.reverse()
      |> Enum.reduce(
        {%{}, [], [], []},
        &split_component_attr(&1, &2, state, type_component)
      )

    {special, roots, attrs, {roots != [], attrs, locs}}
  end

  defp split_component_attr(
         {:root, {:expr, value, %{line: line, column: col}}, _attr_meta},
         {special, r, a, locs},
         state,
         _type_component
       ) do
    quoted_value = Code.string_to_quoted!(value, line: line, column: col, file: state.file)
    quoted_value = quote line: line, do: Map.new(unquote(quoted_value))
    {special, [quoted_value | r], a, locs}
  end

  @special_attrs ~w(:let :if :for :key)
  defp split_component_attr({":key", _expr, attr_meta}, _, state, {"slot", slot_name}) do
    message = ":key is not supported on slots: #{slot_name}"
    raise_syntax_error!(message, attr_meta, state)
  end

  defp split_component_attr(
         {attr, {:expr, value, %{line: line, column: col} = meta}, attr_meta},
         {special, r, a, locs},
         state,
         _type_component
       )
       when attr in @special_attrs do
    case special do
      %{^attr => {_, attr_meta}} ->
        message = """
        cannot define multiple #{attr} attributes. \
        Another #{attr} has already been defined at line #{meta.line}\
        """

        raise_syntax_error!(message, attr_meta, state)

      %{} ->
        quoted_value = Code.string_to_quoted!(value, line: line, column: col, file: state.file)
        validate_quoted_special_attr!(attr, quoted_value, attr_meta, state)
        {Map.put(special, attr, {quoted_value, attr_meta}), r, a, locs}
    end
  end

  defp split_component_attr({attr, _, meta}, _state, state, {type, component_or_slot}) when attr in @special_attrs do
    message = "#{attr} must be a pattern between {...} in #{type}: #{component_or_slot}"
    raise_syntax_error!(message, meta, state)
  end

  defp split_component_attr({":" <> _ = name, _, meta}, _state, state, {type, component_or_slot}) do
    message = "unsupported attribute #{inspect(name)} in #{type}: #{component_or_slot}"
    raise_syntax_error!(message, meta, state)
  end

  defp split_component_attr(
         {name, {:expr, value, %{line: line, column: col}}, attr_meta},
         {special, r, a, locs},
         state,
         _type_component
       ) do
    quoted_value = Code.string_to_quoted!(value, line: line, column: col, file: state.file)
    {special, r, [{String.to_atom(name), quoted_value} | a], [line_column(attr_meta) | locs]}
  end

  defp split_component_attr({name, {:string, value, _meta}, attr_meta}, {special, r, a, locs}, _state, _type_component) do
    {special, r, [{String.to_atom(name), value} | a], [line_column(attr_meta) | locs]}
  end

  defp split_component_attr({name, nil, attr_meta}, {special, r, a, locs}, _state, _type_component) do
    {special, r, [{String.to_atom(name), true} | a], [line_column(attr_meta) | locs]}
  end

  defp line_column(%{line: line, column: column}), do: {line, column}

  defp merge_component_attrs(roots, attrs, line) do
    entries =
      case {roots, attrs} do
        {[], []} -> [{:%{}, [], []}]
        {_, []} -> roots
        {_, _} -> roots ++ [{:%{}, [], attrs}]
      end

    Enum.reduce(entries, fn expr, acc ->
      quote line: line, do: Map.merge(unquote(acc), unquote(expr))
    end)
  end

  defp decompose_remote_component_tag!(tag_name, tag_meta, state) do
    %{line: line, column: column} = tag_meta

    case tag_name |> String.split(".") |> Enum.reverse() do
      [<<first, _::binary>> = fun_name | [_ | _] = rest] when first in ?a..?z ->
        # Standard Phoenix HEEx: <Module.function /> → Module.function(assigns)
        size = byte_size(tag_name) - byte_size(fun_name) + 1
        aliases = rest |> Enum.reverse() |> Enum.map(&String.to_atom/1)
        fun = String.to_atom(fun_name)
        {{:__aliases__, [line: line, column: column], aliases}, size, fun}

      [_ | _] = parts ->
        # Filament-style: <Module /> or <Alias.Module /> → Module.render(assigns)
        aliases = parts |> Enum.reverse() |> Enum.map(&String.to_atom/1)
        {{:__aliases__, [line: line, column: column], aliases}, byte_size(tag_name), :render}

      _ ->
        message = "invalid tag <#{tag_meta.tag_name}>"
        raise_syntax_error!(message, tag_meta, state)
    end
  end

  @doc false
  def __unmatched_let__!(pattern, value) do
    message = """
    cannot match arguments sent from render_slot/2 against the pattern in :let.

    Expected a value matching `#{pattern}`, got: #{inspect(value)}\
    """

    stacktrace =
      self()
      |> Process.info(:current_stacktrace)
      |> elem(1)
      |> Enum.drop(2)

    reraise(message, stacktrace)
  end

  defp raise_if_let!(let, file) do
    with {_pattern, %{line: line}} <- let do
      message = "cannot use :let on a component without inner content"
      raise CompileError, line: line, file: file, description: message
    end
  end

  defp store_component_call(component, attr_info, slot_info, line, %{caller: caller} = state) do
    module = caller.module

    if module && Module.open?(module) do
      do_store_component_call(module, component, attr_info, slot_info, line, state)
    end
  end

  defp do_store_component_call(module, component, attr_info, slot_info, line, state) do
    pruned_slots = prune_slot_info(slot_info)
    {root?, attrs, locs} = attr_info
    pruned_attrs = attrs_for_call(attrs, locs)

    call = %{
      component: component,
      slots: pruned_slots,
      attrs: pruned_attrs,
      file: state.file,
      line: line,
      root: root?
    }

    # This may still fail under a very specific scenario where
    # we are defining a template dynamically inside a function
    # (most likely a test) that starts running while the module
    # is still open.
    try do
      Module.put_attribute(module, :__components_calls__, call)
    rescue
      _ -> :ok
    end
  end

  defp prune_slot_info(slot_info) do
    for {slot_name, slot_values} <- slot_info, into: %{} do
      values =
        for {tag_meta, {root?, attrs, locs}} <- slot_values do
          %{line: tag_meta.line, root: root?, attrs: attrs_for_call(attrs, locs)}
        end

      {slot_name, values}
    end
  end

  defp attrs_for_call(attrs, locs) do
    for {{attr, value}, {line, column}} <- Enum.zip(attrs, locs),
        do: {attr, {line, column, attr_type(value)}},
        into: %{}
  end

  defp attr_type({:<<>>, _, _} = value), do: {:string, value}
  defp attr_type(value) when is_list(value), do: {:list, value}
  defp attr_type({:%{}, _, _} = value), do: {:map, value}
  defp attr_type(value) when is_binary(value), do: {:string, value}
  defp attr_type(value) when is_integer(value), do: {:integer, value}
  defp attr_type(value) when is_float(value), do: {:float, value}
  defp attr_type(value) when is_boolean(value), do: {:boolean, value}
  defp attr_type(value) when is_atom(value), do: {:atom, value}
  defp attr_type({:fn, _, [{:->, _, [args, _]}]}), do: {:fun, length(args)}
  defp attr_type({:&, _, [{:/, _, [_, arity]}]}), do: {:fun, arity}

  # this could be a &myfun(&1, &2)
  defp attr_type({:&, _, args}) do
    {_ast, arity} =
      Macro.prewalk(args, 0, fn
        {:&, _, [n]} = ast, acc when is_integer(n) ->
          {ast, max(n, acc)}

        ast, acc ->
          {ast, acc}
      end)

    (arity > 0 && {:fun, arity}) || :any
  end

  defp attr_type(_value), do: :any

  ## Helpers

  defp to_location(%{line: line, column: column}), do: [line: line, column: column]

  defp actual_component_module(env, fun) do
    case Macro.Env.lookup_import(env, {fun, 1}) do
      [{_, module} | _] -> module
      _ -> env.module
    end
  end

  # removes phx-no-format, etc. and maps phx-hook=".name" to the fully qualified name
  defp postprocess_attrs(attrs, state) do
    attrs_to_remove = ~w(phx-no-format phx-no-curly-interpolation)

    for {key, value, meta} <- attrs,
        key not in attrs_to_remove do
      case {key, value, meta} do
        {"phx-hook", {:string, "." <> name, str_meta}, meta} ->
          {key, {:string, "#{inspect(state.caller.module)}.#{name}", str_meta}, meta}

        _ ->
          {key, value, meta}
      end
    end
  end

  defp validate_tag_attrs!(attrs, %{tag_name: "input"}, state) do
    # warn if using name="id" on an input
    case Enum.find(attrs, &match?({"name", {:string, "id", _}, _}, &1)) do
      {_name, _value, attr_meta} ->
        meta = [
          line: attr_meta.line,
          column: attr_meta.column,
          file: state.file,
          module: state.caller.module,
          function: state.caller.function
        ]

        IO.warn(
          """
          Setting the "name" attribute to "id" on an input tag overrides the ID of the corresponding form element.
          This leads to unexpected behavior, especially when using LiveView, and is not recommended.

          You should use a different value for the "name" attribute, e.g. "_id" and remap the value in the
          corresponding handle_event/3 callback or controller.
          """,
          meta
        )

      _ ->
        :ok
    end
  end

  defp validate_tag_attrs!(_attrs, _meta, _state), do: :ok

  # Check if `phx-update`, `phx-hook` is present in attrs and raises in case
  # there is no ID attribute set.
  defp validate_phx_attrs!(attrs, meta, state) do
    validate_phx_attrs!(attrs, meta, state, nil, false)
  end

  defp validate_phx_attrs!([], meta, state, attr, false) when attr in ["phx-update", "phx-hook"] do
    message = "attribute \"#{attr}\" requires the \"id\" attribute to be set"

    raise_syntax_error!(message, meta, state)
  end

  defp validate_phx_attrs!([], _meta, _state, _attr, _id?), do: :ok

  # Handle <div phx-update="ignore" {@some_var}>Content</div> since here the ID
  # might be inserted dynamically so we can't raise at compile time.
  defp validate_phx_attrs!([{:root, _, _} | t], meta, state, attr, _id?),
    do: validate_phx_attrs!(t, meta, state, attr, true)

  defp validate_phx_attrs!([{"id", _, _} | t], meta, state, attr, _id?),
    do: validate_phx_attrs!(t, meta, state, attr, true)

  defp validate_phx_attrs!([{"phx-update", {:string, value, _meta}, attr_meta} | t], meta, state, _attr, id?) do
    cond do
      value in ~w(ignore stream replace) ->
        validate_phx_attrs!(t, meta, state, "phx-update", id?)

      value in ~w(append prepend) ->
        line = meta[:line] || state.caller.line

        IO.warn(
          "phx-update=\"#{value}\" is deprecated, please use streams instead",
          Macro.Env.stacktrace(%{state.caller | line: line})
        )

        validate_phx_attrs!(t, meta, state, "phx-update", id?)

      true ->
        message =
          "the value of the attribute \"phx-update\" must be: ignore, stream, append, prepend, or replace"

        raise_syntax_error!(message, attr_meta, state)
    end
  end

  defp validate_phx_attrs!([{"phx-update", _attrs, _} | t], meta, state, _attr, id?) do
    validate_phx_attrs!(t, meta, state, "phx-update", id?)
  end

  defp validate_phx_attrs!([{"phx-hook", _, _} | t], meta, state, _attr, id?),
    do: validate_phx_attrs!(t, meta, state, "phx-hook", id?)

  defp validate_phx_attrs!([{special, value, attr_meta} | t], meta, state, attr, id?)
       when special in ~w(:if :for :type) do
    case value do
      {:expr, _, _} ->
        validate_phx_attrs!(t, meta, state, attr, id?)

      _ ->
        message = "#{special} must be an expression between {...}"
        raise_syntax_error!(message, attr_meta, state)
    end
  end

  defp validate_phx_attrs!([{":" <> name, _, attr_meta} | _], _meta, state, _attr, _id?)
       when name not in ~w(if for key) do
    message = "unsupported attribute :#{name} in tags"
    raise_syntax_error!(message, attr_meta, state)
  end

  defp validate_phx_attrs!([_h | t], meta, state, attr, id?), do: validate_phx_attrs!(t, meta, state, attr, id?)

  defp validate_quoted_special_attr!(attr, quoted_value, attr_meta, state) do
    if attr == ":for" and not match?({:<-, _, [_, _]}, quoted_value) do
      message = ":for must be a generator expression (pattern <- enumerable) between {...}"

      raise_syntax_error!(message, attr_meta, state)
    else
      :ok
    end
  end

  defp expand_with_line(ast, line, env) do
    Macro.expand(ast, %{env | line: line})
  end

  defp raise_syntax_error!(message, meta, state) do
    raise ParseError,
      line: meta.line,
      column: meta.column,
      file: state.file,
      description: message <> ParseError.code_snippet(state.source, meta, state.indentation)
  end

  defp maybe_anno_caller(state, meta, file, line) do
    if anno = state.tag_handler.annotate_caller(file, line) do
      update_subengine(state, :handle_text, [meta, anno])
    else
      state
    end
  end
end
