defmodule Filament.InterpolationTest do
  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe

  defmodule Child do
    @moduledoc false
    use Filament.Component

    def render(%{value: initial}) do
      {value, _} = use_state(initial)
      ~F"<b>{value}</b>"
    end
  end

  defmodule Template do
    @moduledoc false
    use Filament.Component

    def render(%{mode: :raw, html: html}), do: ~F"<div>{Phoenix.HTML.raw(html)}</div>"

    def render(%{mode: :loop}) do
      ~F"<ul><%= for x <- [1, 2] do %><li>{x}</li><% end %></ul>"
    end

    def render(%{mode: :list}) do
      children = [[{:component, Child, %{value: "one"}, "a"}], {:component, Child, %{value: "two"}, "b"}]
      ~F"<div>{children}</div>"
    end

    def render(%{mode: :bind, value: value}) do
      ~F"""
      <div><i>{value}</i><% upper = String.upcase(value) %><b>{upper}</b><%= for x <- [1, 2] do %><% y = x * 10 %><u>{y}</u><% end %></div>
      """
    end

    def render(%{mode: :scalar, value: value}), do: ~F"{value}"
    def render(%{mode: :iodata}), do: ~F|<div>{["<", [38, "hello"], 62]}</div>|
  end

  defp assert_paths(props, expected) do
    {tree, walked, _} = Filament.Reconciler.mount(Template, props, owner_pid: self())
    assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() == expected
    assert walked |> Filament.Web.to_rendered() |> Safe.to_iodata() |> IO.iodata_to_binary() == expected
    view = Filament.Test.mount!(Template, props)
    assert view.rendered_html == expected
    tree
  end

  test "raw HTML survives the substrate walker" do
    assert_paths(%{mode: :raw, html: "<b>hello</b>"}, "<div><b>hello</b></div>")
  end

  test "EEx for blocks produce renderable vnode lists" do
    assert_paths(%{mode: :loop}, "<ul><li>1</li><li>2</li></ul>")
  end

  test "nested vnode lists register child fibers and preserve hooks" do
    props = %{mode: :list}
    tree = assert_paths(props, "<div><b>one</b><b>two</b></div>")
    assert map_size(tree) == 3
    [child | _] = tree["root"].children
    {:rerender, tree} = Filament.StateHelper.apply_set_state(tree, child, 0, "changed")
    {_, walked, _} = Filament.Reconciler.update(tree, "root", props, owner_pid: self())
    assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<b>changed</b>"
  end

  test "scalar roots and ordinary iodata remain escaped" do
    assert_paths(%{mode: :scalar, value: "<script>"}, "&lt;script&gt;")
    assert_paths(%{mode: :scalar, value: 123}, "123")
    assert_paths(%{mode: :scalar, value: nil}, "")
    assert_paths(%{mode: :iodata}, "<div>&lt;&amp;hello&gt;</div>")
  end

  test "variables bound by <% %> are visible to later siblings on every target" do
    expected = "<div><i>a</i><b>A</b><u>10</u><u>20</u></div>"
    assert_paths(%{mode: :bind, value: "a"}, expected)

    {tree, output, _} = Filament.Reconciler.mount(Template, %{mode: :bind, value: "a"}, target: Filament.Web)
    assert output |> Filament.Web.to_iodata() |> IO.iodata_to_binary() == expected
    Filament.Reconciler.unmount(tree)
  end
end
