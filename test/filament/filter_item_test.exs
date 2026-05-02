defmodule Filament.FilterItemTest do
  use ExUnit.Case, async: true

  alias Filament.{Reconciler, FiberTree}

  @filters [all: "All", active: "Active", completed: "Done"]

  describe "FilterBar with FilterItem sub-components" do
    test "renders filter buttons as HTML" do
      {_tree, rendered, _} =
        Reconciler.mount(TodoWeb.Components.FilterBar, %{filters: @filters, default: :all},
          owner_pid: self()
        )

      html = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "All"
      assert html =~ "Active"
      assert html =~ "Done"
    end

    test "active item has selected class" do
      {_tree, rendered, _} =
        Reconciler.mount(TodoWeb.Components.FilterBar, %{filters: @filters, default: :active},
          owner_pid: self()
        )

      html = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ ~s(class="selected")
    end

    test "each FilterItem gets its own fiber" do
      {tree, _rendered, _} =
        Reconciler.mount(TodoWeb.Components.FilterBar, %{filters: @filters, default: :all},
          owner_pid: self()
        )

      fiber_ids = FiberTree.fiber_ids(tree)
      # root fiber for FilterBar + one fiber per FilterItem (3 items)
      assert length(fiber_ids) == 4
    end

    test "on_click handler exists for each item" do
      {tree, _rendered, _} =
        Reconciler.mount(TodoWeb.Components.FilterBar, %{filters: @filters, default: :all},
          owner_pid: self()
        )

      fiber_ids = FiberTree.fiber_ids(tree)
      item_fibers = fiber_ids -- ["root"]

      for fiber_id <- item_fibers do
        handler = FiberTree.get_event_handler(tree, fiber_id, 0)
        assert is_function(handler), "expected handler at slot 0 for fiber #{fiber_id}"
      end
    end
  end
end
