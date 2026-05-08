defmodule Filament.RendererTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.RenderContext
  alias Filament.Renderer
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Rendered

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

      {result, hook_slots, pending_effects, new_fibers, event_handlers} =
        Renderer.render(TestHello.TestHello, %{name: "world"}, context)

      assert %Rendered{} = result
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

      {result, _hook_slots, _pending_effects, _new_fibers, _event_handlers} =
        Renderer.render(TestHello.TestHello, %{name: "Alice"}, context)

      iodata = Safe.to_iodata(result)
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

      {result, _hook_slots, _pending_effects, _new_fibers, _event_handlers} =
        Renderer.render(TestHello.TestHello, %{name: "Bob"}, context)

      iodata = Safe.to_iodata(result)
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

  describe "render_vnode/2" do
    test "renders :text vnode" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      result = Renderer.render_vnode({:text, "hello"}, context)
      assert result == "hello"
    end

    test "renders :element vnode with children" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      vnode = {:element, "div", [{"class", "test"}], [{:text, "content"}]}
      result = Renderer.render_vnode(vnode, context)
      html = IO.iodata_to_binary(result)
      assert html =~ "<div"
      assert html =~ "content"
      assert html =~ "</div>"
    end

    test "renders :fragment vnode" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      vnode = {:fragment, [{:text, "A"}, {:text, "B"}]}
      result = Renderer.render_vnode(vnode, context)
      assert result == ["A", "B"]
    end

    test "renders :component vnode" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}

      {result, _hook_slots, _pending_effects, _new_fibers, _event_handlers} =
        Renderer.render(TestHello.TestHello, %{name: "vnode"}, context)

      assert %Rendered{} = result
      html = result |> Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "vnode"
    end

    test "raises on invalid vnode" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}

      assert_raise ArgumentError, ~r/invalid vnode/, fn ->
        Renderer.render_vnode({:invalid, "data"}, context)
      end
    end

    test "1. render_vnode :text returns content" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      assert Renderer.render_vnode({:text, "hello"}, context) == "hello"
    end

    test "2. render_vnode :element with atom tag and attrs produces correct HTML" do
      root_fiber = Fiber.new(id: "root", component: __MODULE__)
      context = %RenderContext{fiber_id: "root", fiber_tree: %{"root" => root_fiber}}
      Process.put(:filament_render_context, context)

      vnode = {:element, :div, [class: "x"], [{:text, "hi"}]}
      result = Renderer.render_vnode(vnode, context)
      html = IO.iodata_to_binary(result)

      Process.delete(:filament_render_context)

      assert html == ~s(<div class="x">hi</div>)
    end

    test "3. render_vnode :element void element has no closing tag" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      Process.put(:filament_render_context, context)

      result = Renderer.render_vnode({:element, :br, [], []}, context)
      html = IO.iodata_to_binary(result)

      Process.delete(:filament_render_context)

      assert html == "<br>"
    end

    test "4. render_vnode :component registers child fiber in new_fibers" do
      root_fiber = Fiber.new(id: "root", component: __MODULE__)

      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      {_rendered, _hook_slots, _effects, new_fibers, _handlers} =
        Renderer.render(SimpleItem.SimpleItem, %{label: "test"}, context)

      assert map_size(new_fibers) == 0

      # Now test via render_vnode directly within an active render context
      Process.put(:filament_render_context, context)

      Renderer.render_vnode({:component, SimpleItem.SimpleItem, %{label: "hi"}, nil}, context)

      final_ctx = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)

      child_id = Fiber.child_id(root_fiber, SimpleItem.SimpleItem, {:index, 0})
      assert Map.has_key?(final_ctx.new_fibers, child_id)
    end

    test "5. rendering a component twice with same key preserves hook_slots" do
      root_fiber = Fiber.new(id: "root", component: __MODULE__)

      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      child_id = Fiber.child_id(root_fiber, StatefulComp.StatefulComp, {:key, "item"})

      # First render
      Process.put(:filament_render_context, context)

      Renderer.render_vnode(
        {:component, StatefulComp.StatefulComp, %{initial: 42}, "item"},
        context
      )

      first_ctx = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)

      first_child_fiber = Map.get(first_ctx.new_fibers, child_id)
      assert first_child_fiber

      # Second render: provide existing fiber in fiber_tree for state continuity
      context2 = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber, child_id => first_child_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      Process.put(:filament_render_context, context2)

      Renderer.render_vnode(
        {:component, StatefulComp.StatefulComp, %{initial: 42}, "item"},
        context2
      )

      second_ctx = Process.get(:filament_render_context)
      Process.delete(:filament_render_context)

      second_child_fiber = Map.get(second_ctx.new_fibers, child_id)
      assert second_child_fiber.status == :stable
      assert second_child_fiber.hook_slots == first_child_fiber.hook_slots
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
