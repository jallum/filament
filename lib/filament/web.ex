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
  def to_iodata(%Phoenix.LiveView.Rendered{} = r), do: Safe.to_iodata(r)

  def to_iodata({:text, content}), do: content

  def to_iodata({:element, tag, attrs, walked_children}) do
    tag_str = to_string(tag)
    rendered_children = Enum.map(walked_children, &to_iodata/1)

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
    Enum.map(walked_children, &to_iodata/1)
  end

  # Transitional shape (Phase 1.2): wraps a `Phoenix.LiveView.Rendered` struct
  # produced by `~F` until Phase 1.4 switches `~F` codegen to emit walked
  # vnodes directly. Side effects (event registration) already ran during
  # `Renderer.render/3`, so this is purely a serialization step.
  def to_iodata({:rendered_struct, %Phoenix.LiveView.Rendered{} = r}) do
    Safe.to_iodata(r)
  end

  # Idempotent: an already-converted `{:safe, iodata}` value passes through.
  def to_iodata({:safe, iodata}), do: iodata

  def to_iodata(invalid) do
    raise ArgumentError, "invalid walked vnode: #{inspect(invalid)}"
  end

  defp embed_child(%Phoenix.LiveView.Rendered{} = r), do: Safe.to_iodata(r)
  defp embed_child({tag, _} = walked_vnode) when is_atom(tag), do: to_iodata(walked_vnode)

  defp embed_child({tag, _, _, _} = walked_vnode) when is_atom(tag),
    do: to_iodata(walked_vnode)

  defp embed_child({tag, _, _, _, _} = walked_vnode) when is_atom(tag),
    do: to_iodata(walked_vnode)

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
          [" ", attr_key, "=\"", ref, "\""]

        _ ->
          render_attr_value(key_str, value)
      end
    end)
  end

  defp render_attr_value(_key_str, false), do: []
  defp render_attr_value(key_str, true), do: [" ", key_str]

  defp render_attr_value(key_str, value) do
    escaped_value = Plug.HTML.html_escape_to_iodata(to_string(value))
    [" ", key_str, "=\"", escaped_value, "\""]
  end
end
