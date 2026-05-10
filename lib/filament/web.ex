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
  def to_rendered(walked) do
    state = %{static: [""], dynamic: [], fp: 0}
    state = walk_rendered(walked, state)
    static = Enum.reverse(state.static)
    dynamic = Enum.reverse(state.dynamic)

    %Rendered{
      static: static,
      dynamic: fn _track -> dynamic end,
      fingerprint: state.fp,
      root: false,
      caller: :not_available
    }
  end

  defp append_static(state, ""), do: state

  defp append_static(%{static: [head | rest]} = state, text) do
    %{state | static: [head <> text | rest]}
  end

  defp push_dynamic(state, value) do
    %{state | static: ["" | state.static], dynamic: [value | state.dynamic]}
  end

  defp fp_mix(state, term) do
    %{state | fp: :erlang.phash2({state.fp, term})}
  end

  defp walk_rendered({:text, content}, state) when is_binary(content) do
    state |> append_static(content) |> fp_mix({:text, content})
  end

  defp walk_rendered({:element, tag, attrs, children}, state) do
    tag_str = to_string(tag)

    state =
      state
      |> append_static("<" <> tag_str)
      |> fp_mix({:elem_open, tag_str})

    state = Enum.reduce(attrs, state, &walk_attr/2)
    state = append_static(state, ">")

    state =
      Enum.reduce(children, state, fn child, st ->
        walk_child_rendered(child, st)
      end)

    if void_element?(tag_str) do
      state
    else
      state |> append_static("</" <> tag_str <> ">") |> fp_mix({:elem_close, tag_str})
    end
  end

  defp walk_rendered({:fragment, children}, state) do
    state = fp_mix(state, :fragment_open)
    state = Enum.reduce(children, state, fn child, st -> walk_child_rendered(child, st) end)
    fp_mix(state, :fragment_close)
  end

  # Component embedding: child render is itself a `%Rendered{}` (when the
  # child component used `~F`) or a walked vnode tree (manual). Either way,
  # we surface it as a single dynamic slot — PLV recursively diffs nested
  # Rendered structs, and walked subtrees fall back to opaque iodata via
  # `Phoenix.HTML.Safe`.
  defp walk_rendered({:component, _mod, _props, _key, child_render}, state) do
    state |> push_dynamic(component_dynamic(child_render)) |> fp_mix(:component)
  end

  defp component_dynamic(%Rendered{} = r), do: r
  defp component_dynamic(other) when is_tuple(other), do: to_rendered(other)
  defp component_dynamic(other), do: other

  defp walk_child_rendered(child, state) when is_tuple(child), do: walk_rendered(child, state)
  defp walk_child_rendered(nil, state), do: state
  defp walk_child_rendered(false, state), do: state

  defp walk_child_rendered(other, state) do
    # Scalar interpolation children get html-escaped via Safe.to_iodata to
    # match the iodata path's behaviour. Pre-escape eagerly so the dynamic
    # slot holds finished iodata that Phoenix can splice without re-walking.
    state |> push_dynamic(Safe.to_iodata(other)) |> fp_mix(:dynamic_child)
  end

  defp walk_attr({_name, false}, state), do: state

  defp walk_attr({name, nil}, state) do
    state |> append_static(" " <> to_string(name)) |> fp_mix({:attr_bool, name})
  end

  defp walk_attr({name, true}, state) do
    state |> append_static(" " <> to_string(name)) |> fp_mix({:attr_bool, name})
  end

  defp walk_attr({name, {:wire_ref, ref}}, state) do
    name_str = to_string(name)
    attr_key = "phx-" <> String.slice(name_str, 3..-1//1)

    state
    |> append_static(" " <> attr_key <> ~s(="filament:) <> ref <> ~s("))
    |> fp_mix({:attr_wire_ref, attr_key})
  end

  defp walk_attr({name, value}, state) when is_binary(value) do
    name_str = to_string(name)

    state
    |> append_static(" " <> name_str <> ~s(="))
    |> push_dynamic(Plug.HTML.html_escape_to_iodata(value))
    |> append_static(~s("))
    |> fp_mix({:attr_dynamic, name_str})
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

  def to_iodata(invalid) do
    raise ArgumentError, "invalid walked vnode: #{inspect(invalid)}"
  end

  # Scalar child of an element/fragment — string from `{name}` interpolation,
  # integer, atom, etc. HTML-escape and emit as iodata. Nil/false render as
  # empty (matches HEEx semantics for `nil` interpolations).
  defp child_to_iodata(child) when is_tuple(child), do: to_iodata(child)
  defp child_to_iodata(nil), do: []
  defp child_to_iodata(false), do: []
  defp child_to_iodata(child), do: Safe.to_iodata(child)

  defp embed_child(%Rendered{} = r), do: Safe.to_iodata(r)
  defp embed_child({tag, _} = walked_vnode) when is_atom(tag), do: to_iodata(walked_vnode)

  defp embed_child({tag, _, _, _} = walked_vnode) when is_atom(tag), do: to_iodata(walked_vnode)

  defp embed_child({tag, _, _, _, _} = walked_vnode) when is_atom(tag), do: to_iodata(walked_vnode)

  defp embed_child(other), do: Safe.to_iodata(other)

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

  defp render_attr_value(_key_str, false), do: []
  defp render_attr_value(key_str, true), do: [" ", key_str]
  # `nil` is emitted by VNodeEngine for bare boolean attrs (`<input disabled>`).
  defp render_attr_value(key_str, nil), do: [" ", key_str]

  defp render_attr_value(key_str, value) do
    escaped_value = Plug.HTML.html_escape_to_iodata(to_string(value))
    [" ", key_str, "=\"", escaped_value, "\""]
  end
end
