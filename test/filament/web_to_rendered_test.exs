defmodule Filament.WebToRenderedTest do
  @moduledoc """
  Phase 1.5.2: `Filament.Web.to_rendered/1` walks a walked vnode tree and
  produces a `%Phoenix.LiveView.Rendered{}` with a proper static/dynamic
  split. PLV's diff engine can then send only the changed dynamic slots
  over the wire instead of full HTML on every interactive update.

  Approach: every attribute *value* and every interpolation child is a
  dynamic slot; element tags, attribute names, and literal text live in
  the static array. Static parts are interleaved between dynamics so
  `length(static) == length(dynamic) + 1`. Fingerprint is a structural
  hash that's stable across renders of the same template shape.
  """
  use ExUnit.Case, async: true

  alias Filament.Web
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Rendered

  defp render(walked), do: Web.to_rendered(walked)

  defp html(walked) do
    walked |> render() |> Safe.to_iodata() |> IO.iodata_to_binary()
  end

  describe "to_rendered/1: shape" do
    test "pure-static text leaf" do
      r = render({:text, "hello"})
      assert %Rendered{} = r
      assert r.static == ["hello"]
      assert r.dynamic.(false) == []
    end

    test "pure-static element" do
      r = render({:element, "div", [], [{:text, "hi"}]})
      assert r.static == ["<div>hi</div>"]
      assert r.dynamic.(false) == []
    end

    test "single interpolation produces one dynamic slot" do
      r = render({:fragment, [{:text, "Hello "}, "World"]})
      assert r.static == ["Hello ", ""]
      assert r.dynamic.(false) == ["World"]
    end

    test "element with one dynamic child" do
      r = render({:element, "p", [], ["x"]})
      assert r.static == ["<p>", "</p>"]
      assert r.dynamic.(false) == ["x"]
    end

    test "element with string attr → attr value is dynamic" do
      # All attr values are dynamic so PLV can diff them per render. Static
      # holds the structural skeleton; values get plugged in.
      r = render({:element, "div", [{"class", "x"}], [{:text, "hi"}]})
      assert r.static == [~s(<div class="), ~s(">hi</div>)]
      assert r.dynamic.(false) == ["x"]
    end

    test "element with wire-ref attr (already-resolved)" do
      r = render({:element, "button", [{"on_click", {:wire_ref, "root:0"}}], [{:text, "x"}]})
      assert r.static == [~s(<button phx-click="filament:root:0">x</button>)]
      assert r.dynamic.(false) == []
    end

    test "void element" do
      r = render({:element, "br", [], []})
      assert r.static == ["<br>"]
      assert r.dynamic.(false) == []
    end

    test "boolean nil attr renders as bare key" do
      r = render({:element, "input", [{"disabled", nil}], []})
      assert r.static == ["<input disabled>"]
      assert r.dynamic.(false) == []
    end
  end

  describe "to_rendered/1: fingerprint stability" do
    test "same shape with different dynamic values → same fingerprint" do
      r1 = render({:fragment, [{:text, "Hello "}, "Alice"]})
      r2 = render({:fragment, [{:text, "Hello "}, "Bob"]})
      assert r1.fingerprint == r2.fingerprint
    end

    test "different shape → different fingerprint" do
      r1 = render({:element, "span", [], [{:text, "x"}]})
      r2 = render({:element, "div", [], [{:text, "x"}]})
      assert r1.fingerprint != r2.fingerprint
    end

    test "different number of dynamic slots → different fingerprint" do
      r1 = render({:fragment, [{:text, "x"}]})
      r2 = render({:fragment, [{:text, "x"}, "y"]})
      assert r1.fingerprint != r2.fingerprint
    end
  end

  describe "to_rendered/1: round-trip vs to_iodata" do
    # The two web emitters MUST agree on the rendered HTML — `to_iodata` is
    # the established reference; `to_rendered` is the diff-aware variant.
    test "static-only tree" do
      walked = {:element, "div", [{"class", "x"}], [{:text, "hi"}]}
      assert html(walked) == walked |> Web.to_iodata() |> IO.iodata_to_binary()
    end

    test "dynamic interpolation" do
      walked = {:fragment, [{:text, "n="}, "42"]}
      assert html(walked) == walked |> Web.to_iodata() |> IO.iodata_to_binary()
    end

    test "wire-ref attr" do
      walked = {:element, "button", [{"on_click", {:wire_ref, "root:0"}}], [{:text, "go"}]}
      assert html(walked) == walked |> Web.to_iodata() |> IO.iodata_to_binary()
    end

    test "fragment with mixed children" do
      walked =
        {:fragment,
         [
           {:element, "span", [], ["a"]},
           {:element, "span", [], ["b"]}
         ]}

      assert html(walked) == walked |> Web.to_iodata() |> IO.iodata_to_binary()
    end

    test "nested elements with dynamic content" do
      walked =
        {:element, "ul", [],
         [{:element, "li", [{"class", "active"}], ["item-1"]}]}

      assert html(walked) == walked |> Web.to_iodata() |> IO.iodata_to_binary()
    end
  end

  describe "to_rendered/1: PLV diff compatibility" do
    test "phoenix can compute a diff between two renders of the same shape" do
      r1 = render({:fragment, [{:text, "n="}, "1"]})
      r2 = render({:fragment, [{:text, "n="}, "2"]})

      # Same fingerprint = same template shape; PLV's diff should recognise
      # only the dynamic slot changed.
      assert r1.fingerprint == r2.fingerprint
      assert r1.dynamic.(false) == ["1"]
      assert r2.dynamic.(false) == ["2"]
    end

    test "rendered embeds in an outer ~H template via Phoenix.HTML.Safe" do
      walked = {:element, "p", [], ["hello"]}
      r = render(walked)

      # The %Rendered{} must be Safe-compatible (so EEx can embed it in
      # the outer LiveView template via `<%= @_filament_rendered %>`).
      assert is_function(r.dynamic)
      iodata = Safe.to_iodata(r)
      assert IO.iodata_to_binary(iodata) == "<p>hello</p>"
    end
  end

  describe "html escaping in dynamic slots" do
    test "scalar string with HTML-special chars is escaped on render" do
      walked = {:fragment, [{:text, "Hello "}, "<script>"]}
      assert html(walked) == "Hello &lt;script&gt;"
    end

    test "scalar attr value with HTML-special chars is escaped" do
      walked = {:element, "div", [{"title", "a\"b"}], []}
      assert html(walked) == ~s(<div title="a&quot;b"></div>)
    end
  end
end
