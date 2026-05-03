defmodule Todo.Test do
  use ExUnit.Case, async: true

  import Filament.Test

  # ── Rung 1: domain ──────────────────────────────────────────────────────────
  alias TodoWeb.Components.TodoList

  describe "Todo.Store" do
    setup do
      %{store: start_supervised!({Todo.Store, []})}
    end

    test "starts empty", %{store: store} do
      assert Todo.Store.list(store) == []
    end

    test "add/2 prepends item with auto-incremented id", %{store: store} do
      _ = Todo.Store.add(store, "Buy milk")
      _ = Todo.Store.add(store, "Write tests")
      items = Todo.Store.list(store)
      assert length(items) == 2
      assert Enum.map(items, & &1.text) == ["Write tests", "Buy milk"]
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
      [first, second] = Todo.Store.list(store)
      assert first.text == "Item two"
      assert second.text == "Item one"

      :ok = Todo.Store.remove(store, second.id)
      assert [%{text: "Item two"}] = Todo.Store.list(store)
    end
  end

  # ── Rung 2: component ───────────────────────────────────────────────────────

  describe "TodoList component" do
    test "renders empty state on first mount" do
      {:ok, view} = mount(TodoList, %{})
      refute view.rendered_html =~ "<li"
    end

    test "adding a todo renders it in the list" do
      {:ok, view} = mount(TodoList, %{})
      {:ok, view} = submit(view, "form", %{"text" => "Buy milk"})
      assert render_text(view) =~ "Buy milk"
    end

    test "multiple todos are all rendered" do
      {:ok, view} = mount(TodoList, %{})
      {:ok, view} = submit(view, "form", %{"text" => "First task"})
      {:ok, view} = submit(view, "form", %{"text" => "Second task"})
      text = render_text(view)
      assert text =~ "First task"
      assert text =~ "Second task"
    end

    test "toggling a todo marks it completed" do
      {:ok, view} = mount(TodoList, %{})
      {:ok, view} = submit(view, "form", %{"text" => "Do laundry"})
      {:ok, view} = click(view, "input.toggle")
      assert view.rendered_html =~ ~s(class="completed)
    end

    test "removing a todo takes it out of the list" do
      {:ok, view} = mount(TodoList, %{})
      {:ok, view} = submit(view, "form", %{"text" => "Temporary task"})
      {:ok, view} = click(view, "button.destroy")
      refute render_text(view) =~ "Temporary task"
    end

    test "filter buttons are rendered when todos exist" do
      {:ok, view} = mount(TodoList, %{})
      {:ok, view} = submit(view, "form", %{"text" => "Task"})
      html = view.rendered_html
      assert html =~ "All"
      assert html =~ "Active"
      assert html =~ "Completed"
    end
  end
end
