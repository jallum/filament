defmodule Filament.FiberTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber

  defmodule TestComponent do
  end

  defmodule AnotherComponent do
  end

  describe "new/1" do
    test "creates fiber with all fields" do
      fiber =
        Fiber.new(
          id: "root",
          component: TestComponent,
          key: "test-key",
          props: %{value: "test"},
          hook_slots: %{0 => :slot_value},
          children: ["child1", "child2"],
          parent_id: "parent",
          status: :stable
        )

      assert fiber.id == "root"
      assert fiber.component == TestComponent
      assert fiber.key == "test-key"
      assert fiber.props == %{value: "test"}
      assert fiber.hook_slots == %{0 => :slot_value}
      assert fiber.children == ["child1", "child2"]
      assert fiber.parent_id == "parent"
      assert fiber.status == :stable
    end

    test "creates fiber with required fields only" do
      fiber = Fiber.new(id: "root", component: TestComponent)

      assert fiber.id == "root"
      assert fiber.component == TestComponent
      assert fiber.key == nil
      assert fiber.props == %{}
      assert fiber.hook_slots == %{}
      assert fiber.children == []
      assert fiber.parent_id == nil
      assert fiber.status == :mounting
    end

    test "raises KeyError when :id is missing" do
      assert_raise KeyError, fn ->
        Fiber.new(component: TestComponent)
      end
    end

    test "raises KeyError when :component is missing" do
      assert_raise KeyError, fn ->
        Fiber.new(id: "root")
      end
    end

    test "sets default status to :mounting" do
      fiber = Fiber.new(id: "root", component: TestComponent)
      assert fiber.status == :mounting

      fiber = Fiber.new(id: "root", component: TestComponent, status: :stable)
      assert fiber.status == :stable
    end
  end

  describe "child_id/3" do
    setup do
      parent = Fiber.new(id: "root", component: TestComponent, status: :stable)
      {:ok, parent: parent}
    end

    test "produces deterministic ID with {:index, 0}", %{parent: parent} do
      child_id = Fiber.child_id(parent, AnotherComponent, {:index, 0})
      assert child_id == "root.Elixir.Filament.FiberTest.AnotherComponent[0]"
    end

    test "produces deterministic ID with {:index, 5}", %{parent: parent} do
      child_id = Fiber.child_id(parent, AnotherComponent, {:index, 5})
      assert child_id == "root.Elixir.Filament.FiberTest.AnotherComponent[5]"
    end

    test "produces deterministic ID with {:key, 'abc'}", %{parent: parent} do
      child_id = Fiber.child_id(parent, AnotherComponent, {:key, "abc"})
      assert child_id == ~S<root.Elixir.Filament.FiberTest.AnotherComponent[key="abc"]>
    end

    test "produces deterministic ID with {:key, 42}", %{parent: parent} do
      child_id = Fiber.child_id(parent, AnotherComponent, {:key, 42})
      assert child_id == "root.Elixir.Filament.FiberTest.AnotherComponent[key=42]"
    end

    test "produces deterministic ID with {:key, :atom}", %{parent: parent} do
      child_id = Fiber.child_id(parent, AnotherComponent, {:key, :atom})
      assert child_id == "root.Elixir.Filament.FiberTest.AnotherComponent[key=:atom]"
    end

    test "is idempotent", %{parent: parent} do
      child_id1 = Fiber.child_id(parent, AnotherComponent, {:index, 0})
      child_id2 = Fiber.child_id(parent, AnotherComponent, {:index, 0})
      assert child_id1 == child_id2
    end

    test "produces different IDs for different keys", %{parent: parent} do
      child_id1 = Fiber.child_id(parent, AnotherComponent, {:key, "key1"})
      child_id2 = Fiber.child_id(parent, AnotherComponent, {:key, "key2"})
      assert child_id1 != child_id2
    end

    test "produces different IDs for different indices", %{parent: parent} do
      child_id1 = Fiber.child_id(parent, AnotherComponent, {:index, 0})
      child_id2 = Fiber.child_id(parent, AnotherComponent, {:index, 1})
      assert child_id1 != child_id2
    end

    test "produces different IDs for index vs key with same value", %{parent: parent} do
      child_id_index = Fiber.child_id(parent, AnotherComponent, {:index, 42})
      child_id_key = Fiber.child_id(parent, AnotherComponent, {:key, 42})
      assert child_id_index != child_id_key
      assert child_id_index == "root.Elixir.Filament.FiberTest.AnotherComponent[42]"
      assert child_id_key == "root.Elixir.Filament.FiberTest.AnotherComponent[key=42]"
    end

    test "works with complex key types", %{parent: parent} do
      # Map key
      child_id = Fiber.child_id(parent, AnotherComponent, {:key, %{id: 42}})
      assert child_id == ~S<root.Elixir.Filament.FiberTest.AnotherComponent[key=%{id: 42}]>

      # Tuple key
      child_id = Fiber.child_id(parent, AnotherComponent, {:key, {:user, 42}})
      assert child_id == ~S<root.Elixir.Filament.FiberTest.AnotherComponent[key={:user, 42}]>
    end

    test "works with complex parent IDs" do
      parent =
        Fiber.new(id: "root.MyComponent[0].Child[1]", component: TestComponent, status: :stable)

      child_id = Fiber.child_id(parent, AnotherComponent, {:key, "nested"})

      assert child_id ==
               ~S<root.MyComponent[0].Child[1].Elixir.Filament.FiberTest.AnotherComponent[key="nested"]>
    end
  end
end
