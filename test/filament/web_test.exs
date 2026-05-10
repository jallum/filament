defmodule Filament.WebTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.RenderContext
  alias Filament.Renderer
  alias Filament.Web

  defmodule Hello do
    @moduledoc false
    use Filament.Component

    defcomponent Hello do
      prop(:name, :string, required: true)

      def render(%{name: name}) do
        ~F"""
        <span>{name}</span>
        """
      end
    end
  end

  describe "to_iodata/1" do
    test "text node" do
      assert Web.to_iodata({:text, "hi"}) == "hi"
    end

    test "element with attrs and children" do
      walked = {:element, "div", [class: "x"], [{:text, "hi"}]}
      html = walked |> Web.to_iodata() |> IO.iodata_to_binary()
      assert html == ~s(<div class="x">hi</div>)
    end

    test "void element has no closing tag" do
      walked = {:element, "br", [], []}
      html = walked |> Web.to_iodata() |> IO.iodata_to_binary()
      assert html == "<br>"
    end

    test "boolean true attribute renders as bare key" do
      walked = {:element, "input", [disabled: true], []}
      html = walked |> Web.to_iodata() |> IO.iodata_to_binary()
      assert html == "<input disabled>"
    end

    test "boolean false attribute is omitted" do
      walked = {:element, "input", [disabled: false], []}
      html = walked |> Web.to_iodata() |> IO.iodata_to_binary()
      assert html == "<input>"
    end

    test "on_* attribute (pre-resolved by walker) becomes phx-* with wire ref" do
      walked = {:element, "button", [on_click: {:wire_ref, "root:0"}], [{:text, "x"}]}
      html = walked |> Web.to_iodata() |> IO.iodata_to_binary()

      assert html =~ ~s(phx-click="filament:root:0")
    end

    test "fragment is a flat list of converted children" do
      walked = {:fragment, [{:text, "a"}, {:text, "b"}]}
      assert Web.to_iodata(walked) |> IO.iodata_to_binary() == "ab"
    end

    test "component embeds child Rendered output" do
      root_fiber = Fiber.new(id: "root", component: __MODULE__)

      ctx = %RenderContext{
        fiber_id: "root",
        fiber_tree: %{"root" => root_fiber},
        new_fibers: %{},
        pending_effects: []
      }

      Process.put(:filament_render_context, ctx)
      walked = Renderer.walk_vnode({:component, Hello.Hello, %{name: "Alice"}, nil}, ctx)
      html = walked |> Web.to_iodata() |> IO.iodata_to_binary()
      Process.delete(:filament_render_context)

      assert html =~ "Alice"
    end

    test "raises on invalid walked vnode" do
      assert_raise ArgumentError, ~r/invalid walked vnode/, fn ->
        Web.to_iodata({:bogus, 1})
      end
    end
  end
end
