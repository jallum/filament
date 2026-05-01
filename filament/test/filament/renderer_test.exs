defmodule Filament.RendererTest do
  use ExUnit.Case, async: true

  alias Filament.{Renderer, RenderContext}

  # Define test component inline
  defmodule TestHello do
    use Filament.Component

    defcomponent TestHello do
      prop :name, :string, required: true

      def render(assigns) do
        ~F"""
        <p>Hello, {@name}!</p>
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

      result = Renderer.render(TestHello.TestHello, %{name: "world"}, context)
      assert %Phoenix.LiveView.Rendered{} = result
    end

    test "produces HTML containing rendered content" do
      context = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{}
      }

      result = Renderer.render(TestHello.TestHello, %{name: "Alice"}, context)
      iodata = Phoenix.HTML.Safe.to_iodata(result)
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

      result = Renderer.render(TestHello.TestHello, %{name: "Bob"}, context)
      iodata = Phoenix.HTML.Safe.to_iodata(result)
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

      # Should restore outer context
      assert Renderer.current_context() == outer_context

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
      assert result == ["content"]
    end

    test "renders :fragment vnode" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      vnode = {:fragment, [{:text, "A"}, {:text, "B"}]}
      result = Renderer.render_vnode(vnode, context)
      assert result == ["A", "B"]
    end

    test "renders :component vnode" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      vnode = {:component, TestHello.TestHello, %{name: "vnode"}, nil}
      result = Renderer.render_vnode(vnode, context)

      assert %Phoenix.LiveView.Rendered{} = result
      html = Phoenix.HTML.Safe.to_iodata(result) |> IO.iodata_to_binary()
      assert html =~ "vnode"
    end

    test "renders :keyed_list vnode" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}
      vnode = {:keyed_list, [
        {:a, {:text, "First"}},
        {:b, {:text, "Second"}}
      ]}
      result = Renderer.render_vnode(vnode, context)
      assert result == ["First", "Second"]
    end

    test "raises on invalid vnode" do
      context = %RenderContext{fiber_id: "root", fiber_tree: %{}}

      assert_raise ArgumentError, ~r/invalid vnode/, fn ->
        Renderer.render_vnode({:invalid, "data"}, context)
      end
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
