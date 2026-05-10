defmodule Filament.FilterItemTest do
  use ExUnit.Case, async: true

  import Filament.Test

  alias Filament.FiberTree
  alias Filament.Reconciler
  alias TodoWeb.Components.FilterBar

  @filters [all: "All", active: "Active", completed: "Done"]

  describe "FilterBar with FilterItem sub-components" do
    test "renders filter buttons as HTML" do
      {_tree, rendered, _} =
        Reconciler.mount(FilterBar, %{filters: @filters, default: :all}, owner_pid: self())

      html = rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "All"
      assert html =~ "Active"
      assert html =~ "Done"
    end

    test "active item has selected class" do
      {_tree, rendered, _} =
        Reconciler.mount(FilterBar, %{filters: @filters, default: :active}, owner_pid: self())

      html = rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert html =~ ~s(class="selected")
    end

    test "each FilterItem gets its own fiber" do
      {tree, _rendered, _} =
        Reconciler.mount(FilterBar, %{filters: @filters, default: :all}, owner_pid: self())

      fiber_ids = FiberTree.fiber_ids(tree)
      # root fiber for FilterBar + one fiber per FilterItem (3 items)
      assert length(fiber_ids) == 4
    end

    test "on_click handler exists for each item" do
      {tree, _rendered, _} =
        Reconciler.mount(FilterBar, %{filters: @filters, default: :all}, owner_pid: self())

      fiber_ids = FiberTree.fiber_ids(tree)
      item_fibers = fiber_ids -- ["root"]

      for fiber_id <- item_fibers do
        handler = FiberTree.get_event_handler(tree, fiber_id, 0)
        assert is_function(handler), "expected handler at slot 0 for fiber #{fiber_id}"
      end
    end

    test "clicking a filter item moves the selected class and fires on_change" do
      test_pid = self()
      on_change = fn val -> send(test_pid, {:filter_changed, val}) end

      view = mount!(FilterBar, %{filters: @filters, default: :all, on_change: on_change})

      assert view.rendered_html =~ ~s(<a class="selected")
      assert view.rendered_html =~ "All"

      view = click!(view, "a[href]")

      assert_receive {:filter_changed, _}
      assert view.rendered_html =~ ~s(class="selected")
    end

    test "clicking Active filter shows Active as selected" do
      test_pid = self()
      on_change = fn val -> send(test_pid, {:filter_changed, val}) end

      view =
        FilterBar |> mount!(%{filters: @filters, default: :all, on_change: on_change}) |> click!("li:nth-child(2) a")

      assert_receive {:filter_changed, :active}
      assert view.rendered_html =~ "Active"
    end
  end
end
