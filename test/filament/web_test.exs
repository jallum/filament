defmodule Filament.WebTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.RenderContext
  alias Filament.Renderer
  alias Filament.Web
  alias Phoenix.HTML.Safe

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
      assert IO.iodata_to_binary(Web.to_iodata({:text, "hi"})) == "hi"
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
      assert walked |> Web.to_iodata() |> IO.iodata_to_binary() == "ab"
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

  defmodule Literal do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props), do: ~F|<p><a href="?a=1&amp;b=2" title="&copy; x">t</a><wbr/><track src="1"/></p>|
    end
  end

  defp both_targets(component) do
    for target <- [Filament.VNode, Web] do
      {tree, output, _} = Filament.Reconciler.mount(component, %{}, target: target)
      Filament.Reconciler.unmount(tree)
      output |> Web.to_iodata() |> IO.iodata_to_binary()
    end
  end

  describe "attribute encoding" do
    test "escapes attribute names, event refs and nested data attributes like HEEx" do
      node =
        {:element, "div",
         [
           {~s(x"><b), "1"},
           {"on_click", {:wire_ref, ~s(root.K[key="a"]:0)}},
           {:data, [foo: "x"]},
           {:aria, [label: "<"]}
         ], []}

      expected =
        ~s(<div x&quot;&gt;&lt;b="1" phx-click="filament:root.K[key=&quot;a&quot;]:0" data-foo="x" aria-label="&lt;"></div>)

      assert IO.iodata_to_binary(Web.to_iodata(node)) == expected
      assert node |> Web.to_rendered() |> Safe.to_iodata() |> IO.iodata_to_binary() == expected
    end

    test "to_iodata and to_rendered encode values the same way" do
      for value <- [{:safe, "<b>"}, ["a", "b"], 1.5, :atom, "a&b"] do
        node = {:element, "i", [{"title", value}], []}

        assert IO.iodata_to_binary(Web.to_iodata(node)) ==
                 node |> Web.to_rendered() |> Safe.to_iodata() |> IO.iodata_to_binary()
      end
    end

    test "literal attribute values and void elements render as written on every target" do
      expected = ~s(<p><a href="?a=1&amp;b=2" title="&copy; x">t</a><wbr><track src="1"></p>)
      assert both_targets(Literal) == [expected, expected]
    end
  end
end
