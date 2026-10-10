defmodule Filament.ConditionalLoopTest do
  use ExUnit.Case, async: true

  alias Filament.Reconciler

  defmodule Leaf do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:v, :any, required: true)

      def render(%{v: v}) do
        send(self(), {:leaf_rendered, v})
        ~F"<b>{v}</b>"
      end
    end
  end

  defmodule Rows do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(%{live: live}) do
        ~F"""
        <ol><li :for={x <- [1, 2]}>{x}{if live do}<Filament.ConditionalLoopTest.Leaf v={live.v} />{end}</li></ol>
        """
      end
    end
  end

  defmodule Branches do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(%{rows: rows}) do
        ~F"""
        <div>{for row <- rows do}{case row do}
          {nil ->}<i>empty</i>
          {%{v: v} ->}<Filament.ConditionalLoopTest.Leaf v={v} /><button on_click={fn -> send(self(), {:clicked, v}) end}>{v}</button>
        {end}{end}</div>
        """
      end
    end
  end

  defp html(rendered), do: rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()

  test "component props stay behind the enclosing if in attribute loops" do
    {tree, rendered, _} = Reconciler.mount(Rows, %{live: nil}, owner_pid: self())
    assert html(rendered) == "<ol><li>1</li><li>2</li></ol>"
    refute_receive {:leaf_rendered, _}
    assert tree["root"].children == []

    {tree, rendered, _} = Reconciler.update(tree, "root", %{live: %{v: "yes"}}, owner_pid: self())
    assert html(rendered) == "<ol><li>1<b>yes</b></li><li>2<b>yes</b></li></ol>"
    assert_receive {:leaf_rendered, "yes"}
    assert_receive {:leaf_rendered, "yes"}
    refute_receive {:leaf_rendered, _}

    {tree, rendered, _} = Reconciler.update(tree, "root", %{live: nil}, owner_pid: self())
    assert html(rendered) == "<ol><li>1</li><li>2</li></ol>"
    assert tree["root"].children == []
    refute_receive {:leaf_rendered, _}
  end

  test "case bindings and conditional handlers retain their scope in block loops" do
    {tree, rendered, _} = Reconciler.mount(Branches, %{rows: [nil, %{v: "yes"}]}, owner_pid: self())
    assert html(rendered) =~ "<i>empty</i>"
    assert html(rendered) =~ "<b>yes</b>"
    assert_receive {:leaf_rendered, "yes"}
    refute_receive {:leaf_rendered, _}
    assert map_size(tree["root"].event_handlers) == 1
    [{handler, :all}] = Map.values(tree["root"].event_handlers)
    handler.()
    assert_receive {:clicked, "yes"}
  end

  defmodule Items do
    @moduledoc false
    use Filament.Component

    defcomponent do
      slot(:item)
      def render(_props), do: ~F"<ul><:item /></ul>"
    end
  end

  defmodule Filtered do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(%{xs: xs}) do
        ~F"""
        <div><Filament.ConditionalLoopTest.Leaf :for={x <- xs} :if={x != "b"} :key={x} v={x} /><Filament.ConditionalLoopTest.Items><:item :for={x <- xs} :if={x != "b"}><i>{x}</i></:item></Filament.ConditionalLoopTest.Items></div>
        """
      end
    end
  end

  test ":if beside :for filters each component and slot iteration on every target" do
    for target <- [Filament.VNode, Filament.Web] do
      {tree, output, _} = Reconciler.mount(Filtered, %{xs: ["a", "b", "c"]}, target: target)

      assert output |> Filament.Web.to_iodata() |> IO.iodata_to_binary() ==
               "<div><b>a</b><b>c</b><ul><i>a</i><i>c</i></ul></div>"

      Reconciler.unmount(tree)
    end
  end

  test "sibling components with the same key raise on every target" do
    for target <- [Filament.VNode, Filament.Web] do
      assert_raise ArgumentError, ~r/duplicate key "a"/, fn ->
        Reconciler.mount(Filtered, %{xs: ["a", "a"]}, target: target)
      end
    end
  end
end
