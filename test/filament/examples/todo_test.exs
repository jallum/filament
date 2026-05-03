defmodule Filament.Examples.TodoTest do
  use ExUnit.Case, async: true
  import Filament.Test

  # ── Rung 1: domain ──────────────────────────────────────────────────────────

  describe "Todo.Store" do
    setup do
      name = :"todo_store_#{System.unique_integer([:positive])}"
      pid = start_supervised!({Todo.Store, name: name})
      %{store: pid}
    end

    test "starts empty", %{store: store} do
      assert Todo.Store.list(store) == []
    end

    test "add/2 prepends item with auto-incremented id", %{store: store} do
      _ = Todo.Store.add(store, "Buy milk")
      _ = Todo.Store.add(store, "Write tests")
      items = Todo.Store.list(store)
      assert length(items) == 2
      # Items are prepended, so most recent is first
      assert Enum.map(items, & &1.text) == ["Write tests", "Buy milk"]
      # IDs are unique integers, first item gets id=1, second gets id=2
      assert Enum.map(items, & &1.id) == [2, 1]
    end

    test "toggle/2 flips the completed flag", %{store: store} do
      _ = Todo.Store.add(store, "Walk dog")
      [item | _] = Todo.Store.list(store)
      refute item.completed

      :ok = Todo.Store.toggle(store, item.id)
      [toggled | _] = Todo.Store.list(store)
      assert toggled.completed

      :ok = Todo.Store.toggle(store, item.id)
      [unset | _] = Todo.Store.list(store)
      refute unset.completed
    end

    test "remove/2 deletes an item", %{store: store} do
      _ = Todo.Store.add(store, "Item one")
      _ = Todo.Store.add(store, "Item two")
      # Items are prepended, so "Item two" is first
      items = Todo.Store.list(store)
      [first, second] = items
      assert first.text == "Item two"
      assert second.text == "Item one"

      :ok = Todo.Store.remove(store, second.id)
      remaining = Todo.Store.list(store)
      assert length(remaining) == 1
      assert hd(remaining).text == "Item two"
    end
  end

  # ── Rung 2: component isolation ─────────────────────────────────────────────
  # NOTE: Component uses Phoenix native events (phx-submit, phx-click) not Filament
  # event refs, so submit/3 and click/2 from Filament.Test cannot dispatch them.
  # These tests verify store-driven rendering instead.

  describe "TodoList component" do
    setup do
      name = :"todo_store_#{System.unique_integer([:positive])}"
      store = start_supervised!({Todo.Store, name: name})
      {:ok, _view} = mount(TodoWeb.Components.TodoList, %{store: store})
      %{store: store}
    end

    test "renders empty state on first mount", %{store: store} do
      {:ok, view} = mount(TodoWeb.Components.TodoList, %{store: store})
      html = view.rendered_html
      refute html =~ "<li"
    end

    test "renders todo items from store", %{store: store} do
      _ = Todo.Store.add(store, "First task")
      _ = Todo.Store.add(store, "Second task")

      # Re-mount fresh so items appear
      {:ok, view} = mount(TodoWeb.Components.TodoList, %{store: store})

      text = render_text(view)
      assert text =~ "First task"
      assert text =~ "Second task"
    end

    test "completed items have 'completed' class", %{store: store} do
      # Add and complete an item
      _ = Todo.Store.add(store, "Done task")
      [item | _] = Todo.Store.list(store)
      :ok = Todo.Store.toggle(store, item.id)

      # Mount with completed item
      {:ok, view} = mount(TodoWeb.Components.TodoList, %{store: store})
      html = view.rendered_html

      # Check for completed class
      assert html =~ "class=\"completed"
    end

    test "filter buttons are present", %{store: store} do
      _ = Todo.Store.add(store, "Task")
      {:ok, view} = mount(TodoWeb.Components.TodoList, %{store: store})

      html = view.rendered_html
      # Filter buttons are anchor tags with on_click handlers
      assert html =~ "<a"
      assert html =~ "All"
      assert html =~ "Active"
      assert html =~ "Completed"
    end

    test "re-render preserves item content", %{store: store} do
      _ = Todo.Store.add(store, "Persistent task")

      # Mount, unmount, remount
      {:ok, view1} = mount(TodoWeb.Components.TodoList, %{store: store})
      text1 = render_text(view1)
      assert text1 =~ "Persistent task"

      # Remount
      {:ok, view2} = mount(TodoWeb.Components.TodoList, %{store: store})
      text2 = render_text(view2)
      assert text2 =~ "Persistent task"
    end
  end
end
