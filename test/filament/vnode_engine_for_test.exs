defmodule Filament.VNodeEngineForTest do
  @moduledoc """
  Phase 1.4.3: `:for` and `:for`+`:key` comprehensions emit fragments of
  vnodes (or keyed components) instead of `Phoenix.LiveView.Comprehension`
  structs.

  Two surfaces:

    1. `:for` attribute on a tag/component — `<Item :for={x <- xs} ... />` and
       optional `:key={k}`.
    2. JSX-block `{for x <- xs do} ... {end}` wrapping a body that may itself
       contain elements/components/text.
  """
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.RenderContext
  alias Filament.Renderer
  alias Filament.TagEngine

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
      subengine: Filament.VNodeEngine,
      tag_handler: Filament.HTMLEngine
    )
  end

  defp eval(ast, bindings) do
    {result, _} = Code.eval_quoted(ast, bindings, __ENV__)
    result
  end

  describe ":for on a self-close component (no :key)" do
    test "produces a fragment of components, one per iteration" do
      ast = compile("<Filament.VNodeEngineForTest.Item.Item :for={x <- xs} label={x}/>")

      result = eval(ast, xs: ["a", "b", "c"])

      assert result ==
               {:fragment,
                [
                  {:component, Item.Item, %{label: "a"}, nil},
                  {:component, Item.Item, %{label: "b"}, nil},
                  {:component, Item.Item, %{label: "c"}, nil}
                ]}
    end

    test "empty list produces an empty fragment" do
      ast = compile("<Filament.VNodeEngineForTest.Item.Item :for={x <- xs} label={x}/>")
      assert eval(ast, xs: []) == {:fragment, []}
    end
  end

  describe ":for + :key on a self-close component" do
    test "produces a fragment of keyed components" do
      ast =
        compile(
          "<Filament.VNodeEngineForTest.Item.Item :for={t <- todos} :key={t.id} label={t.label}/>"
        )

      result =
        eval(ast,
          todos: [%{id: 1, label: "alpha"}, %{id: 2, label: "beta"}]
        )

      assert result ==
               {:fragment,
                [
                  {:component, Item.Item, %{label: "alpha"}, 1},
                  {:component, Item.Item, %{label: "beta"}, 2}
                ]}
    end
  end

  describe "JSX-block {for x <- xs do} ... {end}" do
    test "wraps body output in a fragment" do
      ast = compile("{for x <- xs do}<span>{x}</span>{end}")

      result = eval(ast, xs: ["a", "b"])

      assert result ==
               {:fragment,
                [
                  {:element, "span", [], ["a"]},
                  {:element, "span", [], ["b"]}
                ]}
    end

    test "loop inside an enclosing element" do
      ast = compile("<ul>{for x <- xs do}<li>{x}</li>{end}</ul>")

      result = eval(ast, xs: ["a", "b"])

      assert result ==
               {:element, "ul", [],
                [
                  {:fragment,
                   [
                     {:element, "li", [], ["a"]},
                     {:element, "li", [], ["b"]}
                   ]}
                ]}
    end
  end

  describe "round-trip through walker preserves keyed reconciliation" do
    test "keyed components get fiber ids by key, stable across reorder" do
      ast =
        compile(
          "<Filament.VNodeEngineForTest.Item.Item :for={t <- todos} :key={t.id} label={t.label}/>"
        )

      todos = [%{id: "a", label: "Alpha"}, %{id: "b", label: "Beta"}]
      vnode = eval(ast, todos: todos)

      root_fiber = Fiber.new(id: "root", component: __MODULE__)

      ctx = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      Process.put(:filament_render_context, ctx)
      _walked = Renderer.walk_vnode(vnode, ctx)
      final_ctx = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)

      child_a = Fiber.child_id(root_fiber, Item.Item, {:key, "a"})
      child_b = Fiber.child_id(root_fiber, Item.Item, {:key, "b"})
      assert Map.has_key?(final_ctx.new_fibers, child_a)
      assert Map.has_key?(final_ctx.new_fibers, child_b)
    end
  end
end
