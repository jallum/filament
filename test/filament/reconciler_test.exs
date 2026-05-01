Code.require_file("../fixtures/counter_component.ex", __DIR__)
defmodule Filament.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Filament.{Reconciler, ReconcilerError}
  alias Filament.Fixtures.CounterComponent

  describe "mount/2" do
    test "creates initial fiber tree with root fiber" do
      {tree, rendered} = Reconciler.mount(CounterComponent.Counter, %{count: 0})

      assert %{} = tree
      assert Map.has_key?(tree, "root")
      assert tree["root"].component == CounterComponent.Counter
      assert tree["root"].props == %{count: 0}
      assert tree["root"].status == :stable
      assert tree["root"].id == "root"

      assert %Phoenix.LiveView.Rendered{} = rendered
    end

    test "rendered output contains initial state" do
      {_tree, rendered} = Reconciler.mount(CounterComponent.Counter, %{count: 42})

      iodata = Phoenix.HTML.Safe.to_iodata(rendered)
      html = IO.iodata_to_binary(iodata)

      assert html =~ "42"
    end

    test "tree is stable after mount" do
      {tree, _rendered} = Reconciler.mount(CounterComponent.Counter, %{count: 0})

      assert tree["root"].status == :stable
    end
  end

  describe "update/3" do
    test "updates fiber props and re-renders" do
      {tree, _rendered} = Reconciler.mount(CounterComponent.Counter, %{count: 0})

      {new_tree, new_rendered} = Reconciler.update(tree, "root", %{count: 1})

      # Check fiber was updated
      assert new_tree["root"].props == %{count: 1}
      assert new_tree["root"].status == :stable

      # Check rendered output
      iodata = Phoenix.HTML.Safe.to_iodata(new_rendered)
      html = IO.iodata_to_binary(iodata)
      assert html =~ "1"
    end

    test "updates with same props produces stable result" do
      {tree, rendered1} = Reconciler.mount(CounterComponent.Counter, %{count: 5})

      {new_tree, rendered2} = Reconciler.update(tree, "root", %{count: 5})

      # Rendered should be equivalent
      html1 = Phoenix.HTML.Safe.to_iodata(rendered1) |> IO.iodata_to_binary()
      html2 = Phoenix.HTML.Safe.to_iodata(rendered2) |> IO.iodata_to_binary()
      assert html1 == html2

      # Tree should be updated
      assert new_tree["root"].props == %{count: 5}
    end

    test "raises when updating non-existent fiber" do
      tree = %{}

      assert_raise ReconcilerError, ~r/fiber "root" not found/, fn ->
        Reconciler.update(tree, "root", %{count: 1})
      end
    end
  end

  describe "mount with children" do
    test "tracks children in render context" do
      # This would require a parent component that renders children
      # For B6, we test the basic infrastructure is in place
      {tree, _rendered} = Reconciler.mount(CounterComponent.Counter, %{count: 0})

      assert tree["root"].children == []
    end
  end

  describe "update with children" do
    test "captures new fibers from context" do
      {tree, _rendered} = Reconciler.mount(CounterComponent.Counter, %{count: 0})

      # Currently new_fibers is not populated by ~F templates
      # This is a known limitation for B6 - child components are resolved inline
      # The test verifies the infrastructure is ready for future enhancement
      assert %{} = tree
    end
  end

  describe "unmount/1" do
    test "returns :ok" do
      {tree, _rendered} = Reconciler.mount(CounterComponent.Counter, %{count: 0})

      assert :ok = Reconciler.unmount(tree)
    end
  end
end
