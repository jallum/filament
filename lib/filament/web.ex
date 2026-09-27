defmodule Filament.Web do
  @moduledoc """
  Web target for Filament's substrate vnode IR.

  Builds `Phoenix.LiveView.Rendered` output directly during reconciliation when
  selected with `target: Filament.Web`. It also converts portable walked vnode
  output through `to_rendered/1` and `to_iodata/1`.

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

  @behaviour Filament.RenderTarget

  alias Filament.Renderer
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
  def to_rendered(%Rendered{} = rendered), do: rendered

  def to_rendered(walked), do: build_rendered(walked, :walked)

  @impl Filament.RenderTarget
  def render(output, _context) when is_tuple(output) or is_list(output), do: build_rendered(output, :reconcile)
  def render(output, _context), do: output

  defp build_rendered(walked, mode) do
    state = {[""], [], 0}
    {static, dynamic, fingerprint} = walk_child_rendered(walked, state, mode)
    static = Enum.reverse(static)
    dynamic = Enum.reverse(dynamic)

    %Rendered{
      static: static,
      dynamic: fn _track -> dynamic end,
      fingerprint: fingerprint,
      root: false,
      caller: :not_available
    }
  end

  defp append_static(state, ""), do: state

  defp append_static({[head | rest], dynamic, fp}, text) do
    {[head <> text | rest], dynamic, fp}
  end

  defp push_dynamic({static, dynamic, fp}, value) do
    {["" | static], [value | dynamic], fp}
  end

  defp fp_mix({static, dynamic, fp}, term) do
    {static, dynamic, :erlang.phash2({fp, term})}
  end

  defp walk_rendered({:text, content}, state, _mode) when is_binary(content) do
    state |> append_static(content) |> fp_mix({:text, content})
  end

  defp walk_rendered({:element, tag, attrs, children}, state, mode) do
    tag_str = to_string(tag)

    state =
      state
      |> append_static("<" <> tag_str)
      |> fp_mix({:elem_open, tag_str})

    state =
      Enum.reduce(attrs, state, fn attr, acc ->
        attr = if mode == :reconcile, do: Renderer.resolve_event_attr(attr), else: attr
        walk_attr(attr, acc)
      end)

    state = append_static(state, ">")

    state =
      Enum.reduce(children, state, fn child, st ->
        walk_child_rendered(child, st, mode)
      end)

    if void_element?(tag_str) do
      state
    else
      state |> append_static("</" <> tag_str <> ">") |> fp_mix({:elem_close, tag_str})
    end
  end

  defp walk_rendered({:fragment, children}, state, mode) do
    state = fp_mix(state, :fragment_open)
    state = Enum.reduce(children, state, fn child, st -> walk_child_rendered(child, st, mode) end)
    fp_mix(state, :fragment_close)
  end

  # Component embedding: child render is itself a `%Rendered{}` (when the
  # child component used `~F`) or a walked vnode tree (manual). Either way,
  # we surface it as a single dynamic slot — PLV recursively diffs nested
  # Rendered structs, and walked subtrees fall back to opaque iodata via
  # `Phoenix.HTML.Safe`.
  defp walk_rendered({:component, _mod, _props, _key, child_render}, state, :walked) do
    state |> push_dynamic(component_dynamic(child_render)) |> fp_mix(:component)
  end

  defp walk_rendered({:component, mod, props, key}, state, :reconcile) do
    child = Renderer.render_component_child(Renderer.current_context(), mod, props, key)
    state |> push_dynamic(component_dynamic(child)) |> fp_mix(:component)
  end

  defp walk_rendered({:slot, _name, [], nil}, state, :reconcile) do
    walk_rendered({:fragment, []}, state, :reconcile)
  end

  defp walk_rendered({:slot, _name, [], default}, state, :reconcile) do
    walk_rendered({:component, default, %{}, nil}, state, :reconcile)
  end

  defp walk_rendered({:slot, _name, entries, _default}, state, :reconcile) do
    state = fp_mix(state, :fragment_open)

    state =
      Enum.reduce(entries, state, fn %Filament.Slot.Entry{render_fn: render}, acc ->
        walk_child_rendered(render.(), acc, :reconcile)
      end)

    fp_mix(state, :fragment_close)
  end

  defp walk_rendered(invalid, _state, :reconcile) do
    raise ArgumentError, "invalid vnode: #{inspect(invalid)}"
  end

  defp component_dynamic(%Rendered{} = r), do: r
  defp component_dynamic(other) when is_tuple(other) or is_list(other), do: to_rendered(other)
  defp component_dynamic(other), do: Safe.to_iodata(other)

  defp walk_child_rendered(children, state, mode) when is_list(children) do
    Enum.reduce(children, state, fn
      codepoint, acc when is_integer(codepoint) ->
        acc |> push_dynamic(Safe.to_iodata([codepoint])) |> fp_mix(:dynamic_child)

      child, acc ->
        walk_child_rendered(child, acc, mode)
    end)
  end

  defp walk_child_rendered({:safe, iodata}, state, _mode), do: state |> push_dynamic(iodata) |> fp_mix(:dynamic_child)
  defp walk_child_rendered(child, state, mode) when is_tuple(child), do: walk_rendered(child, state, mode)
  defp walk_child_rendered(nil, state, _mode), do: state
  defp walk_child_rendered(false, state, _mode), do: state

  defp walk_child_rendered(other, state, _mode) do
    # Scalar interpolation children get html-escaped via Safe.to_iodata to
    # match the iodata path's behaviour. Pre-escape eagerly so the dynamic
    # slot holds finished iodata that Phoenix can splice without re-walking.
    state |> push_dynamic(Safe.to_iodata(other)) |> fp_mix(:dynamic_child)
  end

  defp walk_attr({_name, value}, state) when value in [nil, false], do: state

  defp walk_attr({name, true}, state) do
    state |> append_static(" " <> to_string(name)) |> fp_mix({:attr_bool, name})
  end

  defp walk_attr({name, {:wire_ref, ref}}, state) do
    name_str = to_string(name)
    attr_key = "phx-" <> String.slice(name_str, 3..-1//1)

    state
    |> append_static(" " <> attr_key <> ~s(="filament:) <> ref <> ~s("))
    |> fp_mix({:attr_wire_ref, attr_key, ref})
  end

  defp walk_attr({name, value}, state) when is_binary(value) do
    name_str = to_string(name)

    state
    |> append_static(" " <> name_str <> ~s(="))
    |> push_dynamic(Plug.HTML.html_escape_to_iodata(value))
    |> append_static(~s("))
    |> fp_mix({:attr_dynamic, name_str})
  end

  defp walk_attr({name, value}, state) when name in ["class", :class] do
    state
    |> append_static(" class=\"")
    |> push_dynamic(Filament.HTMLEngine.class_attribute_encode(value))
    |> append_static("\"")
    |> fp_mix({:attr_dynamic, "class"})
  end

  defp walk_attr({name, value}, state) when is_list(value) do
    joined = value |> Enum.filter(& &1) |> Enum.join(" ")
    walk_attr({name, joined}, state)
  end

  defp walk_attr({name, value}, state) do
    name_str = to_string(name)

    state
    |> append_static(" " <> name_str <> ~s(="))
    |> push_dynamic(Safe.to_iodata(value))
    |> append_static(~s("))
    |> fp_mix({:attr_dynamic, name_str})
  end

  @doc """
  Converts a walked vnode tree into HTML iodata.

  Accepts:

    * `{:text, content}` — text leaf
    * `{:element, tag, attrs, walked_children}` — HTML element
    * `{:component, mod, props, key, child_render}` — child component, where
      `child_render` is the captured render output (a `Phoenix.LiveView.Rendered`
      struct or another walked vnode tree)
    * `{:fragment, walked_children}` — flat list of children

  """
  @spec to_iodata(term()) :: iodata()
  def to_iodata(%Rendered{} = r), do: Safe.to_iodata(r)

  def to_iodata({:text, content}), do: content

  def to_iodata({:element, tag, attrs, walked_children}) do
    tag_str = to_string(tag)
    rendered_children = Enum.map(walked_children, &child_to_iodata/1)

    if void_element?(tag_str) do
      ["<", tag_str, render_attrs(attrs), ">"]
    else
      ["<", tag_str, render_attrs(attrs), ">", rendered_children, "</", tag_str, ">"]
    end
  end

  def to_iodata({:component, _mod, _props, _key, child_render}) do
    embed_child(child_render)
  end

  def to_iodata({:fragment, walked_children}) do
    Enum.map(walked_children, &child_to_iodata/1)
  end

  # Idempotent: an already-converted `{:safe, iodata}` value passes through.
  def to_iodata({:safe, iodata}), do: iodata

  def to_iodata(children) when is_list(children) do
    Enum.map(children, fn
      codepoint when is_integer(codepoint) -> Safe.to_iodata([codepoint])
      child -> child_to_iodata(child)
    end)
  end

  def to_iodata(nil), do: []
  def to_iodata(false), do: []

  def to_iodata(invalid) when is_tuple(invalid) do
    raise ArgumentError, "invalid walked vnode: #{inspect(invalid)}"
  end

  def to_iodata(scalar), do: Safe.to_iodata(scalar)

  # Scalar child of an element/fragment — string from `{name}` interpolation,
  # integer, atom, etc. HTML-escape and emit as iodata. Nil/false render as
  # empty (matches HEEx semantics for `nil` interpolations).
  defp child_to_iodata(child) when is_tuple(child) or is_list(child), do: to_iodata(child)
  defp child_to_iodata(nil), do: []
  defp child_to_iodata(false), do: []
  defp child_to_iodata(child), do: Safe.to_iodata(child)

  defp embed_child(%Rendered{} = r), do: Safe.to_iodata(r)
  defp embed_child({tag, _} = walked_vnode) when is_atom(tag), do: to_iodata(walked_vnode)

  defp embed_child({tag, _, _, _} = walked_vnode) when is_atom(tag), do: to_iodata(walked_vnode)

  defp embed_child({tag, _, _, _, _} = walked_vnode) when is_atom(tag), do: to_iodata(walked_vnode)

  defp embed_child(other), do: child_to_iodata(other)

  defp void_element?("br"), do: true
  defp void_element?("hr"), do: true
  defp void_element?("input"), do: true
  defp void_element?("img"), do: true
  defp void_element?("meta"), do: true
  defp void_element?("link"), do: true
  defp void_element?("area"), do: true
  defp void_element?("base"), do: true
  defp void_element?("col"), do: true
  defp void_element?("embed"), do: true
  defp void_element?("param"), do: true
  defp void_element?("source"), do: true
  defp void_element?("track"), do: true
  defp void_element?("wbr"), do: true
  defp void_element?(_), do: false

  defp render_attrs([]), do: ""

  defp render_attrs(attrs) do
    Enum.map(attrs, fn {key, value} ->
      key_str = to_string(key)

      case value do
        {:wire_ref, ref} ->
          attr_key = "phx-" <> String.slice(key_str, 3..-1//1)
          [" ", attr_key, "=\"filament:", ref, "\""]

        _ ->
          render_attr_value(key_str, value)
      end
    end)
  end

  defp render_attr_value(_key_str, value) when value in [nil, false], do: []
  defp render_attr_value(key_str, true), do: [" ", key_str]

  defp render_attr_value("class", value) do
    [" class=\"", Filament.HTMLEngine.class_attribute_encode(value), "\""]
  end

  defp render_attr_value(key_str, value) do
    escaped_value = Plug.HTML.html_escape_to_iodata(to_string(value))
    [" ", key_str, "=\"", escaped_value, "\""]
  end
end
