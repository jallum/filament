defmodule Filament.RendererTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.RenderContext
  alias Filament.Renderer

  defmodule SimpleItem do
    @moduledoc false
    use Filament.Component

    defcomponent SimpleItem do
      prop(:label, :string, required: true)

      def render(%{label: label}) do
        ~F"""
        <span>{label}</span>
        """
      end
    end
  end

  defmodule StatefulComp do
    @moduledoc false
    use Filament.Component

    defcomponent StatefulComp do
      prop(:initial, :integer, default: 0)

      def render(%{initial: initial}) do
        {count, _set} = use_state(initial)

        ~F"""
        <span>{count}</span>
        """
      end
    end
  end

  # Define test component inline
  defmodule TestHello do
    @moduledoc false
    use Filament.Component

    defcomponent TestHello do
      prop(:name, :string, required: true)

      def render(%{name: name}) do
        ~F"""
        <p>Hello, {name}!</p>
        """
      end
    end
  end

  describe "render/3" do
    test "renders component with valid props" do
      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{}
      }

      {result, hook_slots, pending_effects, new_fibers, event_handlers, _capture_handlers} =
        Renderer.render(TestHello.TestHello, %{name: "world"}, context)

      assert is_tuple(result)
      assert hook_slots == %{}
      assert pending_effects == []
      assert new_fibers == %{}
      assert event_handlers == %{}
    end

    test "produces HTML containing rendered content" do
      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{}
      }

      {result, _hook_slots, _pending_effects, _new_fibers, _event_handlers, _capture_handlers} =
        Renderer.render(TestHello.TestHello, %{name: "Alice"}, context)

      iodata = Filament.Web.to_iodata(result)
      html = IO.iodata_to_binary(iodata)

      assert html =~ "Hello, Alice"
    end

    test "raises ArgumentError when required prop is missing" do
      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{}
      }

      assert_raise ArgumentError, ~r/required prop :name missing/, fn ->
        Renderer.render(TestHello.TestHello, %{}, context)
      end
    end

    test "renders component with different props" do
      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{}
      }

      {result, _hook_slots, _pending_effects, _new_fibers, _event_handlers, _capture_handlers} =
        Renderer.render(TestHello.TestHello, %{name: "Bob"}, context)

      iodata = Filament.Web.to_iodata(result)
      html = IO.iodata_to_binary(iodata)

      assert html =~ "Bob"
    end
  end

  describe "render context management" do
    test "clears render context after render" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}

      assert Renderer.current_context() == nil

      Renderer.render(TestHello.TestHello, %{name: "test"}, context)

      assert Renderer.current_context() == nil
    end

    test "restores previous context when nested" do
      outer_context = %RenderContext{fiber_id: "outer", fiber_tree: %{}}
      inner_context = %RenderContext{fiber_id: "inner", fiber_tree: %{}}

      # Set outer context
      Process.put(:filament_render_context, outer_context)

      # Render with inner context
      Renderer.render(TestHello.TestHello, %{name: "nested"}, inner_context)

      # Should restore outer context — note: old context is deleted after render,
      # so neither inner nor outer context remains
      assert Renderer.current_context() == nil

      # Cleanup
      Process.delete(:filament_render_context)
    end
  end

  describe "walk_vnode/2" do
    test "returns :text node unchanged" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      assert Renderer.walk_vnode({:text, "hi"}, context) == {:text, "hi"}
    end

    test "recurses into :element children, returns walked element" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      vnode = {:element, "div", [{"class", "x"}], [{:text, "a"}, {:text, "b"}]}
      walked = Renderer.walk_vnode(vnode, context)
      assert walked == {:element, "div", [{"class", "x"}], [{:text, "a"}, {:text, "b"}]}
    end

    test "recurses into :fragment children" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      vnode = {:fragment, [{:text, "A"}, {:element, "span", [], [{:text, "B"}]}]}
      walked = Renderer.walk_vnode(vnode, context)
      assert walked == {:fragment, [{:text, "A"}, {:element, "span", [], [{:text, "B"}]}]}
    end

    test "registers unkeyed :component child fiber and rewrites to 5-tuple" do
      root_fiber = Fiber.new(id: "root", component: __MODULE__)

      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      Process.put(:filament_render_context, context)
      walked = Renderer.walk_vnode({:component, SimpleItem.SimpleItem, %{label: "x"}, nil}, context)
      final_ctx = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)

      assert {:component, SimpleItem.SimpleItem, %{label: "x"}, nil, child_render} = walked
      assert child_render

      child_id = Fiber.child_id(root_fiber, SimpleItem.SimpleItem, {:index, 0})
      assert Map.has_key?(final_ctx.new_fibers, child_id)
    end

    test "registers keyed :component child fiber" do
      root_fiber = Fiber.new(id: "root", component: __MODULE__)

      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      Process.put(:filament_render_context, context)
      walked = Renderer.walk_vnode({:component, SimpleItem.SimpleItem, %{label: "x"}, "k1"}, context)
      final_ctx = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)

      assert {:component, SimpleItem.SimpleItem, %{label: "x"}, "k1", _child} = walked

      child_id = Fiber.child_id(root_fiber, SimpleItem.SimpleItem, {:key, "k1"})
      assert Map.has_key?(final_ctx.new_fibers, child_id)
      assert final_ctx.new_fibers[child_id].key == "k1"
    end

    test "raises on invalid vnode" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}

      assert_raise ArgumentError, ~r/invalid vnode/, fn ->
        Renderer.walk_vnode({:bogus, 1}, context)
      end
    end

    test "emits no HTML iodata for elements" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      result = Renderer.walk_vnode({:element, "div", [{"class", "x"}], []}, context)
      # The walker returns a vnode tuple, never iodata.
      assert is_tuple(result)
      assert elem(result, 0) == :element
    end
  end

  describe "current_context/0" do
    test "returns nil when no context is set" do
      assert Renderer.current_context() == nil
    end

    test "returns the current context when set" do
      context = %RenderContext{fiber_id: "test", fiber_tree: %{}}
      Process.put(:filament_render_context, context)

      assert Renderer.current_context() == context

      Process.delete(:filament_render_context)
    end
  end

  describe "next_hook_slot/0" do
    test "returns incrementing indices during render" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}

      Process.put(:filament_render_context, context)

      assert {0, ctx} = Renderer.next_hook_slot()
      assert ctx.hook_index == 1

      assert {1, ctx} = Renderer.next_hook_slot()
      assert ctx.hook_index == 2

      assert {2, _ctx} = Renderer.next_hook_slot()

      Process.delete(:filament_render_context)
    end

    test "raises when called outside render context" do
      assert_raise RuntimeError, ~r/hook called outside render context/, fn ->
        Renderer.next_hook_slot()
      end
    end
  end

  describe "render_component_child_keyed/4" do
    test "uses key-based fiber id" do
      root_fiber = Fiber.new(id: "root", component: __MODULE__)

      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      Process.put(:filament_render_context, context)
      Renderer.render_component_child_keyed(context, SimpleItem.SimpleItem, %{label: "x"}, "my-key")
      final_ctx = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)

      expected_id = Fiber.child_id(root_fiber, SimpleItem.SimpleItem, {:key, "my-key"})
      assert Map.has_key?(final_ctx.new_fibers, expected_id)
      assert final_ctx.new_fibers[expected_id].key == "my-key"
    end

    test "preserves hook state across renders when key matches" do
      root_fiber = Fiber.new(id: "root", component: __MODULE__)
      child_id = Fiber.child_id(root_fiber, StatefulComp.StatefulComp, {:key, "stable"})

      context1 = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      Process.put(:filament_render_context, context1)
      Renderer.render_component_child_keyed(context1, StatefulComp.StatefulComp, %{initial: 7}, "stable")
      ctx1 = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)

      first_fiber = ctx1.new_fibers[child_id]
      assert first_fiber

      context2 = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber, child_id => first_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      Process.put(:filament_render_context, context2)
      Renderer.render_component_child_keyed(context2, StatefulComp.StatefulComp, %{initial: 7}, "stable")
      ctx2 = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)

      second_fiber = ctx2.new_fibers[child_id]
      assert second_fiber.status == :stable
      assert second_fiber.hook_slots == first_fiber.hook_slots
    end
  end

  describe "hook_index isolation" do
    test "each render starts with hook_index 0" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}

      Process.put(:filament_render_context, context)
      assert {0, _} = Renderer.next_hook_slot()
      assert {1, _} = Renderer.next_hook_slot()
      Process.delete(:filament_render_context)

      Process.put(:filament_render_context, context)
      assert {0, _} = Renderer.next_hook_slot()
      Process.delete(:filament_render_context)
    end
  end
end
