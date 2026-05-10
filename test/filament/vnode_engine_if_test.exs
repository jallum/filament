defmodule Filament.VNodeEngineIfTest do
  @moduledoc """
  Phase 1.4.4: conditionals — `:if={cond}` attribute on element/component
  and JSX-block `{if cond do} ... {else} ... {end}` lower to a regular
  `if` that returns a vnode (or `nil`) at runtime. The substrate walker
  and web converter both treat `nil` as "no content" so a false branch
  produces empty HTML cleanly.
  Slots are out of scope here: components with inner content stay on the
  legacy text path. They're tracked separately if real example apps end
  up needing them.
  """
  use ExUnit.Case, async: true

  alias Filament.RenderContext
  alias Filament.Renderer
  alias Filament.TagEngine
  alias Filament.Web

  defmodule Item do
    @moduledoc false
    use Filament.Component

    defcomponent Item do
      prop(:label, :string, default: "")
      def render(%{label: label}), do: ~F"<span>{label}</span>"
    end
  end

  defp compile(source, env \\ __ENV__) do
    TagEngine.compile(source,
      caller: env,
      file: env.file,
      line: env.line,
      indentation: 0,
      tag_handler: Filament.HTMLEngine
    )
  end

  defp eval(ast, bindings) do
    {result, _} = Code.eval_quoted(ast, bindings, __ENV__)
    result
  end

  describe ":if on an element" do
    test "true branch returns the element" do
      ast = compile("<div :if={visible}>hi</div>")
      assert eval(ast, visible: true) == {:element, "div", [], [{:text, "hi"}]}
    end

    test "false branch returns nil" do
      ast = compile("<div :if={visible}>hi</div>")
      assert eval(ast, visible: false) == nil
    end

    test "nil child gets dropped by walker + web converter" do
      ast = compile("<ul><li :if={show}>x</li></ul>")
      vnode = eval(ast, show: false)
      ctx = %RenderContext{fiber_id: "root", fiber_tree: %{}, new_fibers: %{}, pending_effects: []}
      Process.put(:filament_render_context, ctx)
      walked = Renderer.walk_vnode(vnode, ctx)
      Process.delete(:filament_render_context)
      html = walked |> Web.to_iodata() |> IO.iodata_to_binary()
      assert html == "<ul></ul>"
    end
  end

  describe ":if on a component" do
    test "true branch returns the component vnode" do
      ast =
        compile("<Filament.VNodeEngineIfTest.Item.Item :if={visible} label={l}/>")

      assert eval(ast, visible: true, l: "x") == {:component, Item.Item, %{label: "x"}, nil}
    end

    test "false branch returns nil" do
      ast =
        compile("<Filament.VNodeEngineIfTest.Item.Item :if={visible} label={l}/>")

      assert eval(ast, visible: false, l: "x") == nil
    end
  end

  describe "JSX-block conditionals" do
    test "{if cond do}...{end} returns body or nil" do
      ast = compile("{if x do}<span>yes</span>{end}")
      assert eval(ast, x: true) == {:element, "span", [], [{:text, "yes"}]}
      assert eval(ast, x: false) == nil
    end

    test "{if cond do}...{else}...{end} picks branch" do
      ast = compile("{if x do}<span>A</span>{else}<span>B</span>{end}")
      assert eval(ast, x: true) == {:element, "span", [], [{:text, "A"}]}
      assert eval(ast, x: false) == {:element, "span", [], [{:text, "B"}]}
    end

    test "JSX block inside an element wraps as a child" do
      ast = compile("<div>{if x do}<span>yes</span>{end}</div>")

      assert eval(ast, x: true) ==
               {:element, "div", [], [{:element, "span", [], [{:text, "yes"}]}]}

      assert eval(ast, x: false) == {:element, "div", [], [nil]}
    end
  end
end
