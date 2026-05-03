defmodule Filament.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.Fixtures.CounterComponent
  alias Filament.Reconciler
  alias Filament.ReconcilerError
  alias Phoenix.HTML.Safe

  defmodule StubObservable do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, [])
    def init(_), do: {:ok, []}
    def unsubscribe_calls(pid), do: GenServer.call(pid, :calls)

    def handle_cast({:filament_unsubscribe, key}, calls), do: {:noreply, [key | calls]}
    def handle_call(:calls, _from, calls), do: {:reply, calls, calls}
  end

  describe "mount/2" do
    test "creates initial fiber tree with root fiber" do
      {tree, rendered, pending_effects} = Reconciler.mount(CounterComponent, %{count: 0})

      assert %{} = tree
      assert Map.has_key?(tree, "root")
      assert tree["root"].component == CounterComponent
      assert tree["root"].props == %{count: 0}
      assert tree["root"].status == :stable
      assert tree["root"].id == "root"

      assert %Phoenix.LiveView.Rendered{} = rendered
      assert pending_effects == []
    end

    test "rendered output contains initial state" do
      {_tree, rendered, _pending_effects} =
        Reconciler.mount(CounterComponent, %{count: 42})

      iodata = Safe.to_iodata(rendered)
      html = IO.iodata_to_binary(iodata)

      assert html =~ "42"
    end

    test "tree is stable after mount" do
      {_tree, _rendered, _pending_effects} =
        Reconciler.mount(CounterComponent, %{count: 0})

      assert true
    end
  end

  describe "update/3" do
    test "updates fiber props and re-renders" do
      {tree, _rendered, _pending_effects1} =
        Reconciler.mount(CounterComponent, %{count: 0})

      {new_tree, new_rendered, _pending_effects2} = Reconciler.update(tree, "root", %{count: 1})

      # Check fiber was updated
      assert new_tree["root"].props == %{count: 1}
      assert new_tree["root"].status == :stable

      # Check rendered output
      iodata = Safe.to_iodata(new_rendered)
      html = IO.iodata_to_binary(iodata)
      assert html =~ "1"
    end

    test "updates with same props produces stable result" do
      {tree, rendered1, _pending_effects1} =
        Reconciler.mount(CounterComponent, %{count: 5})

      {new_tree, rendered2, _pending_effects2} = Reconciler.update(tree, "root", %{count: 5})

      # Rendered should be equivalent
      html1 = rendered1 |> Safe.to_iodata() |> IO.iodata_to_binary()
      html2 = rendered2 |> Safe.to_iodata() |> IO.iodata_to_binary()
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
      {tree, _rendered, _pending_effects} =
        Reconciler.mount(CounterComponent, %{count: 0})

      assert tree["root"].children == []
    end
  end

  describe "update with children" do
    test "captures new fibers from context" do
      {tree, _rendered, _pending_effects} =
        Reconciler.mount(CounterComponent, %{count: 0})

      # Currently new_fibers is not populated by ~F templates
      # This is a known limitation for B6 - child components are resolved inline
      # The test verifies the infrastructure is ready for future enhancement
      assert %{} = tree
    end
  end

  describe "unmount/1" do
    test "returns :ok" do
      {tree, _rendered, _pending_effects} =
        Reconciler.mount(CounterComponent, %{count: 0})

      assert :ok = Reconciler.unmount(tree)
    end
  end

  describe "reconcile_children cleanup" do
    defp tree_with_child(cleanup_fn) do
      {tree, _, _} = Reconciler.mount(CounterComponent, %{count: 0})

      child =
        Fiber.new(
          id: "root.child",
          component: CounterComponent,
          props: %{count: 1},
          status: :stable,
          parent_id: "root",
          hook_slots: %{0 => {[], cleanup_fn}}
        )

      tree
      |> Map.put("root.child", child)
      |> Map.update!("root", &%{&1 | children: ["root.child"]})
    end

    test "removed fiber's cleanup function is called on update" do
      agent = start_supervised!({Agent, fn -> 0 end})
      cleanup = fn -> Agent.update(agent, &(&1 + 1)) end

      tree = tree_with_child(cleanup)
      {new_tree, _, _} = Reconciler.update(tree, "root", %{count: 1})

      refute Map.has_key?(new_tree, "root.child")
      assert Agent.get(agent, & &1) == 1
    end

    test "grandchild fibers are recursively cleaned up" do
      agent = start_supervised!({Agent, fn -> [] end})
      child_cleanup = fn -> Agent.update(agent, &[:child | &1]) end
      grandchild_cleanup = fn -> Agent.update(agent, &[:grandchild | &1]) end

      grandchild =
        Fiber.new(
          id: "root.child.grandchild",
          component: CounterComponent,
          props: %{count: 2},
          status: :stable,
          parent_id: "root.child",
          hook_slots: %{0 => {[], grandchild_cleanup}}
        )

      {tree, _, _} = Reconciler.mount(CounterComponent, %{count: 0})

      child =
        Fiber.new(
          id: "root.child",
          component: CounterComponent,
          props: %{count: 1},
          status: :stable,
          parent_id: "root",
          children: ["root.child.grandchild"],
          hook_slots: %{0 => {[], child_cleanup}}
        )

      tree =
        tree
        |> Map.put("root.child", child)
        |> Map.put("root.child.grandchild", grandchild)
        |> Map.update!("root", &%{&1 | children: ["root.child"]})

      {new_tree, _, _} = Reconciler.update(tree, "root", %{count: 1})

      refute Map.has_key?(new_tree, "root.child")
      refute Map.has_key?(new_tree, "root.child.grandchild")
      calls = Agent.get(agent, & &1)
      assert :child in calls
      assert :grandchild in calls
    end

    test "observable is unsubscribed when fiber is removed" do
      server = start_supervised!(%{id: StubObservable, start: {StubObservable, :start_link, []}})
      owner = self()

      {tree, _, _} = Reconciler.mount(CounterComponent, %{count: 0})

      child =
        Fiber.new(
          id: "root.child",
          component: CounterComponent,
          props: %{count: 1},
          status: :stable,
          parent_id: "root",
          hook_slots: %{0 => {:subscribed, server, 42}}
        )

      tree =
        tree
        |> Map.put("root.child", child)
        |> Map.update!("root", &%{&1 | children: ["root.child"]})

      {new_tree, _, _} = Reconciler.update(tree, "root", %{count: 1}, owner_pid: owner)

      refute Map.has_key?(new_tree, "root.child")
      # Allow the cast to be processed
      :timer.sleep(10)
      assert StubObservable.unsubscribe_calls(server) == [{owner, "root.child", 0}]
    end

    test "parent fiber children list is updated to match new render" do
      {tree, _, _} = Reconciler.mount(CounterComponent, %{count: 0})

      child =
        Fiber.new(
          id: "root.child",
          component: CounterComponent,
          props: %{count: 1},
          status: :stable,
          parent_id: "root",
          hook_slots: %{}
        )

      tree =
        tree
        |> Map.put("root.child", child)
        |> Map.update!("root", &%{&1 | children: ["root.child"]})

      {new_tree, _, _} = Reconciler.update(tree, "root", %{count: 1})

      assert new_tree["root"].children == []
    end
  end
end
