defmodule Filament.NestedForTest do
  use ExUnit.Case, async: true

  alias Filament.FiberTree
  alias Filament.Reconciler

  test "nested {for} binds the inner item in markup and event closures" do
    defmodule NestedSets do
      @moduledoc false
      use Filament.Component

      defcomponent List do
        def render(%{groups: groups}) do
          ~F"""
          <dl>
            {for group <- groups do}
              <dt>{group.name}</dt>
              <dd>
                {for set <- group.sets do}
                  <button on_click={fn -> send(self(), {:selected, set.tag}) end}>{set.label}</button>
                {end}
              </dd>
            {end}
          </dl>
          """
        end
      end
    end

    groups = [
      %{name: "First", sets: [%{tag: :one, label: "One"}, %{tag: :two, label: "Two"}]},
      %{name: "Second", sets: [%{tag: :three, label: "Three"}]}
    ]

    {tree, rendered, _} = Reconciler.mount(NestedSets.List, %{groups: groups}, owner_pid: self())
    html = rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()

    assert html =~ "First"
    assert html =~ "Second"
    assert html =~ "One"
    assert html =~ "Two"
    assert html =~ "Three"

    FiberTree.get_event_handler(tree, "root", 0).()
    assert_receive {:selected, :one}
    FiberTree.get_event_handler(tree, "root", 1).()
    assert_receive {:selected, :two}
    FiberTree.get_event_handler(tree, "root", 2).()
    assert_receive {:selected, :three}
  end

  test "nested {for} binds tuple-pattern variables" do
    defmodule NestedTuples do
      @moduledoc false
      use Filament.Component

      defcomponent List do
        def render(%{groups: groups}) do
          ~F"""
          <dl>
            {for group <- groups do}
              <dd>
                {for {tag, label} <- group.sets do}
                  <button on_click={fn -> send(self(), {:selected, tag}) end}>{label}</button>
                {end}
              </dd>
            {end}
          </dl>
          """
        end
      end
    end

    groups = [%{sets: [{:one, "One"}]}]
    {tree, rendered, _} = Reconciler.mount(NestedTuples.List, %{groups: groups}, owner_pid: self())
    html = rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
    assert html =~ "One"

    FiberTree.get_event_handler(tree, "root", 0).()
    assert_receive {:selected, :one}
  end

  test "nested {for} renders child components while the render context is active" do
    defmodule NestedChildren do
      @moduledoc false
      use Filament.Component

      defcomponent Item do
        def render(%{label: label}), do: ~F"<strong>{label}</strong>"
      end

      defcomponent List do
        def render(%{groups: groups}) do
          ~F"""
          <div>
            {for group <- groups do}
              {for item <- group.items do}
                <Item label={item.label} />
              {end}
            {end}
          </div>
          """
        end
      end
    end

    groups = [%{items: [%{label: "One"}, %{label: "Two"}]}]
    {_tree, rendered, _} = Reconciler.mount(NestedChildren.List, %{groups: groups}, owner_pid: self())
    html = rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
    assert html =~ "<strong>One</strong>"
    assert html =~ "<strong>Two</strong>"
  end

  test "an inner generator can shadow a changing outer value" do
    defmodule ShadowedName do
      @moduledoc false
      use Filament.Component

      defcomponent List do
        def render(%{groups: groups, set: set}) do
          ~F"""
          <div>
            {for group <- groups do}
              <span>{set}</span>
              {for set <- group.sets do}
                <button on_click={fn -> send(self(), set.tag) end}>{set.label}</button>
              {end}
            {end}
          </div>
          """
        end
      end
    end

    groups = [%{sets: [%{tag: :item, label: "Item"}]}]
    {tree, first, _} = Reconciler.mount(ShadowedName.List, %{groups: groups, set: "old"}, owner_pid: self())
    assert first |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<span>old</span>"

    {_tree, second, _} =
      Reconciler.update(tree, "root", %{groups: groups, set: "new"}, owner_pid: self())

    assert second |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<span>new</span>"
  end
end
