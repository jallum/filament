defmodule Filament.VNodeEngineTest do
  @moduledoc """
  Tests for the vnode-emitting subengine. The subengine is plugged into
  `Filament.TagEngine.compile/2` via `subengine: Filament.VNodeEngine` and
  receives the tag/text/expr events TagEngine emits during template compilation.

  Phase 1.4.1 scope: text leaves, expression interpolation, plain HTML
  elements with attrs (literal + expression + boolean), void elements, and
  nesting. Components, comprehensions, conditionals, and slots are out of
  scope here — covered by 1.4.2/1.4.3/1.4.4 respectively.
  """
  use ExUnit.Case, async: true

  alias Filament.TagEngine

  # Compile a `~F`-style template source through VNodeEngine and return the
  # quoted AST. Tests then bind expression-side variables and evaluate the AST.
  defp compile(source, env \\ __ENV__) do
    TagEngine.compile(source,
      caller: env,
      file: env.file,
      line: env.line,
      indentation: 0,
      subengine: Filament.VNodeEngine,
      tag_handler: Filament.HTMLEngine
    )
  end

  defp eval(ast, bindings \\ []) do
    {result, _} = Code.eval_quoted(ast, bindings, __ENV__)
    result
  end

  describe "text and expression leaves" do
    test "plain text only" do
      assert eval(compile("hello")) == {:text, "hello"}
    end

    test "single expression interpolation" do
      ast = compile("{name}")
      assert eval(ast, name: "world") == "world"
    end

    test "text + expression sequence wraps in fragment" do
      ast = compile("hello {name}!")
      assert eval(ast, name: "world") == {:fragment, [{:text, "hello "}, "world", {:text, "!"}]}
    end
  end

  describe "plain HTML elements" do
    test "empty element" do
      assert eval(compile("<div></div>")) == {:element, "div", [], []}
    end

    test "element with text content" do
      assert eval(compile("<div>hi</div>")) == {:element, "div", [], [{:text, "hi"}]}
    end

    test "element with expression interpolation" do
      ast = compile("<div>{x}</div>")
      assert eval(ast, x: "abc") == {:element, "div", [], ["abc"]}
    end

    test "element with literal string attribute" do
      assert eval(compile(~s(<div class="x">hi</div>))) ==
               {:element, "div", [{"class", "x"}], [{:text, "hi"}]}
    end

    test "element with expression attribute" do
      ast = compile("<div class={c}>hi</div>")
      assert eval(ast, c: "ny") == {:element, "div", [{"class", "ny"}], [{:text, "hi"}]}
    end

    test "element with multiple attributes" do
      ast = compile(~s(<div id="a" class={c}>x</div>))
      assert eval(ast, c: "y") ==
               {:element, "div", [{"id", "a"}, {"class", "y"}], [{:text, "x"}]}
    end

    test "boolean attribute (no value) is preserved as nil" do
      # `<input disabled>` — TagEngine emits `disabled` with no value.
      assert eval(compile("<input disabled>")) ==
               {:element, "input", [{"disabled", nil}], []}
    end

    test "void elements emit empty children list" do
      assert eval(compile("<br>")) == {:element, "br", [], []}
      assert eval(compile("<hr>")) == {:element, "hr", [], []}
    end

    test "self-closing void elements" do
      # TagEngine treats `<br/>` and `<br>` equivalently for void tags.
      assert eval(compile("<br/>")) == {:element, "br", [], []}
    end

    test "nested elements" do
      assert eval(compile("<div><span>x</span></div>")) ==
               {:element, "div", [], [{:element, "span", [], [{:text, "x"}]}]}
    end

    test "deeply nested" do
      ast = compile("<a><b><c>{v}</c></b></a>")

      assert eval(ast, v: "deep") ==
               {:element, "a", [],
                [{:element, "b", [], [{:element, "c", [], ["deep"]}]}]}
    end

    test "siblings inside an element preserve order" do
      assert eval(compile("<div><span>a</span><span>b</span></div>")) ==
               {:element, "div", [],
                [
                  {:element, "span", [], [{:text, "a"}]},
                  {:element, "span", [], [{:text, "b"}]}
                ]}
    end

    test "multiple top-level elements wrap in fragment" do
      assert eval(compile("<span>a</span><span>b</span>")) ==
               {:fragment,
                [
                  {:element, "span", [], [{:text, "a"}]},
                  {:element, "span", [], [{:text, "b"}]}
                ]}
    end
  end

  describe "interaction with the substrate walker and web converter" do
    alias Filament.RenderContext
    alias Filament.Renderer
    alias Filament.Web

    test "vnode tree round-trips through walk_vnode + Web.to_iodata" do
      ast = compile(~s(<div class={c}>hello {name}</div>))
      vnode = eval(ast, c: "greeting", name: "world")

      ctx = %RenderContext{fiber_id: "root", fiber_tree: %{}, new_fibers: %{}, pending_effects: []}
      Process.put(:filament_render_context, ctx)
      walked = Renderer.walk_vnode(vnode, ctx)
      Process.delete(:filament_render_context)

      html = walked |> Web.to_iodata() |> IO.iodata_to_binary()
      assert html =~ ~s(<div class="greeting">)
      assert html =~ "hello "
      assert html =~ "world"
      assert html =~ "</div>"
    end
  end
end
