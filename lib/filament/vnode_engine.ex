defmodule Filament.VNodeEngine do
  @moduledoc """
  EEx subengine that emits Filament vnode-tree AST instead of
  `Phoenix.LiveView.Rendered` structs.

  Plugs into `Filament.TagEngine.compile/2` via the `subengine:` option.
  TagEngine detects the optional `handle_tag/3` callback below and switches
  to structured tag-open/tag-close emission, so this engine never has to
  parse HTML markup back out of `handle_text` strings.

  ## Output shape

  At runtime, the AST returned from `handle_body/2` evaluates to one of:

    * `{:text, "literal text"}` for a single text leaf
    * `expr_value` for a single interpolation
    * `{:element, name, attrs, children}` for a single root element
    * `{:fragment, [child1, child2, ...]}` when the template has multiple
      top-level children (text + element, two siblings, etc.)

  Phase 1.4.1 scope: text nodes, expression interpolation, plain HTML
  elements with literal/expression/boolean attrs, void/self-closing tags,
  arbitrary nesting. Components, comprehensions, conditionals, and slots
  are added in 1.4.2/1.4.3/1.4.4.
  """

  @doc false
  def init(_opts) do
    %{stack: [], root: []}
  end

  @doc false
  def handle_begin(_state) do
    %{stack: [], root: []}
  end

  @doc false
  def handle_end(state), do: handle_body(state, [])

  @doc false
  def handle_body(state, _opts) do
    case state.root |> Enum.reverse() do
      [] -> quote(do: {:text, ""})
      [single] -> single
      multiple -> fragment_ast(multiple)
    end
  end

  @doc false
  def handle_text(state, _meta, "") do
    state
  end

  def handle_text(state, _meta, text) do
    push_child(state, text_ast(text))
  end

  @doc false
  def handle_expr(state, "=", expr) do
    push_child(state, expr)
  end

  def handle_expr(state, "", expr) do
    # `<% expr %>` (no `=` marker) — side-effect expression, no value emitted.
    # We still need to evaluate it at runtime, so prepend it to the next child
    # in a block. For simplicity, we attach a `_ = expr` to the children list.
    push_child(state, quote(do: (_ = unquote(expr); {:text, ""})))
  end

  def handle_expr(state, _marker, _expr), do: state

  # Optional structured-tag callback. TagEngine detects this via
  # `function_exported?/3` and switches to structured emission when present.
  @doc false
  def handle_tag(state, {:open, name, attrs, true = _void?}, _meta) do
    push_child(state, element_ast(name, attrs, []))
  end

  def handle_tag(state, {:open, name, attrs, false}, _meta) do
    push_frame(state, name, attrs)
  end

  def handle_tag(state, {:close, _name}, _meta) do
    {{name, attrs, children_rev}, state} = pop_frame(state)
    push_child(state, element_ast(name, attrs, Enum.reverse(children_rev)))
  end

  # ── Stack management ──────────────────────────────────────────────────────

  defp push_child(%{stack: []} = state, child_ast) do
    %{state | root: [child_ast | state.root]}
  end

  defp push_child(%{stack: [{n, a, c} | rest]} = state, child_ast) do
    %{state | stack: [{n, a, [child_ast | c]} | rest]}
  end

  defp push_frame(state, name, attrs) do
    %{state | stack: [{name, attrs, []} | state.stack]}
  end

  defp pop_frame(%{stack: [top | rest]} = state) do
    {top, %{state | stack: rest}}
  end

  # ── AST builders ──────────────────────────────────────────────────────────

  # `{:text, "..."}` is a 2-tuple; AST representation is the literal tuple.
  defp text_ast(text) when is_binary(text), do: {:text, text}

  # `{:fragment, [...]}` is a 2-tuple; the children list itself is already an
  # AST list (each element is either a literal vnode tuple or an expression
  # AST), so we can embed it directly.
  defp fragment_ast(children_ast_list) do
    {:fragment, children_ast_list}
  end

  # `{:element, name, attrs, children}` is a 4-tuple, requiring the explicit
  # `:{}` AST node. `attrs` and `children` are lists whose elements are a mix
  # of compile-time literals (e.g., `{"class", "x"}` for a literal attr) and
  # expression ASTs (e.g., the user's `c` for `class={c}`). Both list forms
  # are valid Elixir AST as-is, so we splice them in.
  defp element_ast(name, attrs, children) do
    {:{}, [], [:element, name, attrs_ast(attrs), children]}
  end

  defp attrs_ast(attrs) do
    Enum.map(attrs, &attr_ast/1)
  end

  # An attr is `{name_string, value}` where value is one of:
  #   - a literal string (from `attr="x"`)
  #   - `nil` (from a bare boolean `disabled`)
  #   - an expression AST (from `attr={...}`)
  #
  # For literals/nil, the 2-tuple is its own AST. For expr ASTs, we still want
  # a 2-tuple where the value position holds the AST that evaluates to the
  # value at runtime — and Elixir's 2-tuple `{a, b}` IS the AST for that, so
  # we just emit it directly.
  defp attr_ast({name, value}), do: {name, value}
end
