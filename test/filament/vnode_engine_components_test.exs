defmodule Filament.VNodeEngineComponentsTest do
  @moduledoc """
  Phase 1.4.2: component tags inside ~F templates compile to `{:component, Mod,
  props, key}` vnode tuples instead of runtime `Filament.TagEngine.component/3`
  calls. Substrate walker (Phase 1.1) registers the child fiber.
  Scope: self-closing components, with optional `:key`. No slots / inner content
  (1.4.4), no `:for` / `:if` (1.4.3, 1.4.4).
  """
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.RenderContext
  alias Filament.Renderer
  alias Filament.TagEngine
  alias Filament.Web
  # A trivial Filament component used as the child target for these tests.
  # Defining it inside the test module keeps it self-contained.
  defmodule Item do
    @moduledoc false
    use Filament.Component

    defcomponent Item do
      prop(:label, :string, default: "")

      def render(%{label: label}) do
        ~F"""
        <span>{label}</span>
        """
      end
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

  defp eval(ast, bindings \\ []) do
    {result, _} = Code.eval_quoted(ast, bindings, __ENV__)
    result
  end

  defp root_ctx do
    root_fiber = Fiber.new(id: "root", component: __MODULE__)

    %RenderContext{
      fiber_id: "root",
      fiber_tree: %{"root" => root_fiber},
      new_fibers: %{},
      pending_effects: []
    }
  end

  describe "component tags emit :component vnodes" do
    test "self-close component with no props" do
      ast =
        compile(
          "<Filament.VNodeEngineComponentsTest.Item.Item/>",
          %{__ENV__ | line: 1}
        )

      assert eval(ast) == {:component, Item.Item, %{}, nil}
    end

    test "self-close component with literal string prop" do
      ast = compile(~s(<Filament.VNodeEngineComponentsTest.Item.Item label="hi"/>))
      assert eval(ast) == {:component, Item.Item, %{label: "hi"}, nil}
    end

    test "self-close component with expression prop" do
      ast = compile("<Filament.VNodeEngineComponentsTest.Item.Item label={l}/>")
      assert eval(ast, l: "world") == {:component, Item.Item, %{label: "world"}, nil}
    end

    test "self-close component with :key" do
      ast = compile("<Filament.VNodeEngineComponentsTest.Item.Item :key={k}/>")
      assert eval(ast, k: "abc") == {:component, Item.Item, %{}, "abc"}
    end

    test "self-close component with prop and :key" do
      ast = compile("<Filament.VNodeEngineComponentsTest.Item.Item label={l} :key={k}/>")
      assert eval(ast, l: "x", k: "y") == {:component, Item.Item, %{label: "x"}, "y"}
    end

    test "component nested inside a regular element" do
      ast = compile("<div><Filament.VNodeEngineComponentsTest.Item.Item/></div>")

      assert eval(ast) ==
               {:element, "div", [], [{:component, Item.Item, %{}, nil}]}
    end
  end

  describe "round-trip through walker and web converter" do
    test "walker registers child fiber for unkeyed component" do
      ast = compile("<Filament.VNodeEngineComponentsTest.Item.Item label={l}/>")
      vnode = eval(ast, l: "Alpha")
      ctx = root_ctx()
      Process.put(:filament_render_context, ctx)
      walked = Renderer.walk_vnode(vnode, ctx)
      final_ctx = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)
      child_id = Fiber.child_id(ctx.fiber_tree["root"], Item.Item, {:index, 0})
      assert Map.has_key?(final_ctx.new_fibers, child_id)
      html = walked |> Web.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "<span>Alpha</span>"
    end

    test "walker registers child fiber for keyed component" do
      ast = compile("<Filament.VNodeEngineComponentsTest.Item.Item :key={k}/>")
      vnode = eval(ast, k: "abc")
      ctx = root_ctx()
      Process.put(:filament_render_context, ctx)
      _walked = Renderer.walk_vnode(vnode, ctx)
      final_ctx = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)
      child_id = Fiber.child_id(ctx.fiber_tree["root"], Item.Item, {:key, "abc"})
      assert Map.has_key?(final_ctx.new_fibers, child_id)
      assert final_ctx.new_fibers[child_id].key == "abc"
    end
  end
end
