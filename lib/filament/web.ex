defmodule Filament.Web do
  @moduledoc """
  Web target for Filament's substrate vnode IR.

  Consumes a walked vnode tree produced by `Filament.Renderer.walk_vnode/2`
  and converts it into HTML iodata suitable for embedding in a
  `Phoenix.LiveView.Rendered` struct.

  This module owns all web-shaped concerns:

    * HTML escaping
    * `on_*` → `phx-*` attribute translation and event-ref minting
    * void element handling
    * embedding child component renders (which may themselves be Rendered
      structs from `~F` or walked vnode trees from a downstream substrate
      pass)

  The substrate walker emits no HTML, no `phx-event` strings, and no
  escapes — those concerns live here.
  """

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Rendered

  @doc """
  Converts a walked vnode tree into a `%Phoenix.LiveView.Rendered{}` with a
  proper static/dynamic split, so PLV's diff engine can send only the
  changed slots over the WebSocket instead of full HTML on every event.

  Layout:
    * `static`  — list of binary chunks (element tags, attribute names,
      literal text). Length = `length(dynamic) + 1`.
    * `dynamic` — list of values (scalar interpolations, dynamic attribute
      values). Each slot is interleaved between adjacent static binaries.
    * `fingerprint` — structural hash that is stable across renders of the
      same template shape (different dynamic values do not change it).

  Treats every attribute value and every interpolation child as a dynamic
  slot. Element tags, attribute names, and `{:text, _}` leaves stay in
  static. `{:wire_ref, _}` markers (post-walker `on_*` attrs) are stable
  per fiber+slot and live in static for fingerprint efficiency.
  """
  @spec to_rendered(term()) :: Rendered.t()
  def to_rendered(%Filament.Template{} = template), do: Filament.Web.Template.to_rendered(template)

  def to_rendered(%Rendered{} = rendered), do: rendered

  def to_rendered(walked) do
    {static, dynamic} = walk_child_rendered(walked, {[""], []})
    static = Enum.reverse(static)
    dynamic = Enum.reverse(dynamic)

    %Rendered{
      static: static,
      dynamic: fn _track -> dynamic end,
      fingerprint: fingerprint(static),
      root: root?(walked),
      caller: :not_available
    }
  end

  # One element at the top, which a LiveComponent's output must be.
  @doc false
  def root?(vnode), do: match?({:element, _, _, _}, vnode)

  # LiveView treats equal fingerprints as the same template, so hash the whole
  # static list rather than a narrow digest of it.
  @doc false
  def fingerprint(static), do: :erlang.md5(:erlang.term_to_binary(static))

  defp append_static(state, ""), do: state
  defp append_static({[head | rest], dynamic}, text), do: {[IO.iodata_to_binary([head, text]) | rest], dynamic}

  defp push_dynamic({static, dynamic}, value), do: {["" | static], [value | dynamic]}

  defp walk_rendered({:text, content}, state) when is_binary(content), do: append_static(state, content)

  defp walk_rendered({:element, tag, attrs, children}, state) do
    tag = to_string(tag)
    state = Enum.reduce(attrs, append_static(state, "<" <> tag), &walk_attr/2)
    state = Enum.reduce(children, append_static(state, ">"), &walk_child_rendered/2)
    if void_element?(tag), do: state, else: append_static(state, "</" <> tag <> ">")
  end

  defp walk_rendered({:fragment, children}, state), do: Enum.reduce(children, state, &walk_child_rendered/2)

  # Component embedding: child render is itself a `%Rendered{}` (when the
  # child component used `~F`) or a walked vnode tree (manual). Either way,
  # we surface it as a single dynamic slot — PLV recursively diffs nested
  # Rendered structs, and walked subtrees fall back to opaque iodata via
  # `Phoenix.HTML.Safe`.
  defp walk_rendered({:component, _mod, _props, _key, child_render}, state) do
    push_dynamic(state, component_dynamic(child_render))
  end

  defp walk_rendered(invalid, _state), do: raise(ArgumentError, "invalid walked vnode: #{inspect(invalid)}")

  defp component_dynamic(%Filament.Template{} = template), do: to_rendered(template)
  defp component_dynamic(%Rendered{} = r), do: r
  defp component_dynamic(other) when is_tuple(other) or is_list(other), do: to_rendered(other)
  defp component_dynamic(other) when other in [nil, false], do: ""
  defp component_dynamic(other), do: Safe.to_iodata(other)

  defp walk_child_rendered(%Filament.Template{} = template, state), do: push_dynamic(state, to_rendered(template))

  defp walk_child_rendered(children, state) when is_list(children) do
    Enum.reduce(children, state, fn
      codepoint, acc when is_integer(codepoint) -> push_dynamic(acc, Safe.to_iodata([codepoint]))
      child, acc -> walk_child_rendered(child, acc)
    end)
  end

  defp walk_child_rendered({:safe, iodata}, state), do: push_dynamic(state, iodata)
  defp walk_child_rendered(child, state) when is_tuple(child), do: walk_rendered(child, state)
  defp walk_child_rendered(nil, state), do: state
  defp walk_child_rendered(false, state), do: state

  defp walk_child_rendered(other, state) do
    # Scalar interpolation children get html-escaped via Safe.to_iodata.
    # Pre-escape eagerly so the dynamic slot holds finished iodata that
    # Phoenix can splice without re-walking.
    push_dynamic(state, Safe.to_iodata(other))
  end

  # Attributes whose output is fixed by name and shape stay static; a value
  # becomes a dynamic slot between ` name="` and `"`.
  defp walk_attr({name, value}, state) do
    cond do
      value in [nil, false, true] or match?({:wire_ref, _}, value) ->
        append_static(state, attribute(name, value))

      nested_attribute?(name, value) ->
        push_dynamic(state, attribute(name, value))

      true ->
        state
        |> append_static([" ", attribute_name(name), ~s(=")])
        |> push_dynamic(attribute_value(name, value))
        |> append_static(~s("))
    end
  end

  @doc false
  # The one attribute encoder for every Web path. Matches HEEx: names and
  # values are escaped, nil and false omit the attribute, true renders it bare,
  # and `data`, `aria` and `phx` keyword lists expand to nested attributes.
  def attribute(_name, value) when value in [nil, false], do: []
  def attribute(name, true), do: [" ", attribute_name(name)]

  def attribute(name, {:wire_ref, ref}) do
    event = name |> to_string() |> String.slice(3..-1//1)
    [" phx-", attribute_name(event), ~s(="filament:), Plug.HTML.html_escape_to_iodata(ref), ~s(")]
  end

  def attribute(name, value) do
    if nested_attribute?(name, value) do
      {:safe, iodata} = Phoenix.HTML.attributes_escape([{to_string(name), value}])
      iodata
    else
      [" ", attribute_name(name), ~s(="), attribute_value(name, value), ~s(")]
    end
  end

  @doc false
  def attribute_value(_name, value) when is_binary(value), do: Plug.HTML.html_escape_to_iodata(value)
  def attribute_value(name, value) when name in ["class", :class], do: Filament.HTMLEngine.class_attribute_encode(value)
  def attribute_value(_name, value), do: Filament.HTMLEngine.empty_attribute_encode(value)

  @doc false
  def nested_attribute?(name, value), do: name in ["data", "aria", "phx", :data, :aria, :phx] and is_list(value)

  defp attribute_name(name), do: name |> to_string() |> Plug.HTML.html_escape()

  @doc """
  Converts a walked vnode tree into HTML iodata.

  Accepts:

    * `{:text, content}` — text leaf
    * `{:element, tag, attrs, walked_children}` — HTML element
    * `{:component, mod, props, key, child_render}` — child component, where
      `child_render` is the captured render output (a `Phoenix.LiveView.Rendered`
      struct or another walked vnode tree)
    * `{:fragment, walked_children}` — flat list of children

  The HTML is exactly what `to_rendered/1` sends to a LiveView client.
  """
  @spec to_iodata(term()) :: iodata()
  def to_iodata(walked), do: walked |> to_rendered() |> Safe.to_iodata()

  @doc false
  # HTML void elements: emitted without a closing tag.
  def void_element?(tag), do: tag in ~w(area base br col embed hr img input link meta param source track wbr)
end
