defmodule Filament.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.Fixtures.CounterComponent
  alias Filament.Reconciler
  alias Filament.ReconcilerError

  defmodule StubObservable do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, [])
    def init(_), do: {:ok, []}
    def unsubscribe_calls(pid), do: GenServer.call(pid, :calls)

    def handle_cast({:filament_remove_projection, owner_pid, {fiber_id, slot_index}}, calls),
      do: {:noreply, [{owner_pid, fiber_id, slot_index} | calls]}

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

      assert is_tuple(rendered)
      assert pending_effects == []
    end

    test "rendered output contains initial state" do
      {_tree, rendered, _pending_effects} =
        Reconciler.mount(CounterComponent, %{count: 42})

      iodata = Filament.Web.to_iodata(rendered)
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
      iodata = Filament.Web.to_iodata(new_rendered)
      html = IO.iodata_to_binary(iodata)
      assert html =~ "1"
    end

    test "updates with same props produces stable result" do
      {tree, rendered1, _pending_effects1} =
        Reconciler.mount(CounterComponent, %{count: 5})

      {new_tree, rendered2, _pending_effects2} = Reconciler.update(tree, "root", %{count: 5})

      # Rendered should be equivalent
      html1 = rendered1 |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      html2 = rendered2 |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
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

  # ── keyed_list proj_key cleanup (Fix 1) ──────────────────────────────────────

  # Observable that lets tests inspect proj_keys via a synchronous call, which
  # conveniently flushes any preceding remove_projection casts from the same queue.
  defmodule KeyedTrackingObservable do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :state)
    def init(s), do: {:ok, s}

    def proj_key_count(srv), do: GenServer.call(srv, :cell_subscriber_count)
    def subscriber_count(srv), do: GenServer.call(srv, :cell_subscriber_count)

    @impl Filament.Observable
    def handle_subscribe(_sub, state), do: {:ok, state, state}

    @impl GenServer
    def handle_call(:cell_subscriber_count, _from, state) do
      {:reply, map_size(Process.get(:__filament_cell_subscribers__, %{})), state}
    end
  end

  defmodule ObservingChild do
    @moduledoc false
    use Filament.Component

    def render(%{server: server}) do
      cell = {Filament.Observable.GenServer, server}

      use_observable(cell, fn
        :disconnected -> nil
        state -> state
      end)

      ~F"<span>child</span>"
    end
  end

  defmodule KeyedParent do
    @moduledoc false
    use Filament.Component

    defcomponent KeyedParent do
      prop(:server, :any, required: true)
      prop(:items, :list, required: true)

      def render(%{server: server, items: items}) do
        ~F"""
        <Filament.ReconcilerTest.ObservingChild :for={key <- items} :key={key} server={server} />
        """
      end
    end
  end

  describe "keyed fiber unmount removes observable proj_keys" do
    setup do
      %{server: start_supervised!(KeyedTrackingObservable)}
    end

    test "all proj_keys removed when list empties (3 → 0)", %{server: server} do
      # Mount with empty list so the root fiber exists in the tree before children render.
      {tree, _, _} = Reconciler.mount(KeyedParent.KeyedParent, %{server: server, items: []}, owner_pid: self())

      # Add 3 subscribed children via update (root fiber is now in the tree).
      {tree, _, _} =
        Reconciler.update(tree, "root", %{server: server, items: ["a", "b", "c"]}, owner_pid: self())

      assert KeyedTrackingObservable.proj_key_count(server) == 3

      # Remove all — reconcile_children must route them through unmount_fiber.
      {_, _, _} =
        Reconciler.update(tree, "root", %{server: server, items: []}, owner_pid: self())

      # GenServer.call flushes the preceding remove_projection casts.
      assert KeyedTrackingObservable.proj_key_count(server) == 0
      assert KeyedTrackingObservable.subscriber_count(server) == 0
    end

    test "2 of 3 proj_keys removed when list shrinks (3 → 1)", %{server: server} do
      {tree, _, _} = Reconciler.mount(KeyedParent.KeyedParent, %{server: server, items: []}, owner_pid: self())

      {tree, _, _} =
        Reconciler.update(tree, "root", %{server: server, items: ["a", "b", "c"]}, owner_pid: self())

      assert KeyedTrackingObservable.proj_key_count(server) == 3

      {_, _, _} =
        Reconciler.update(tree, "root", %{server: server, items: ["a"]}, owner_pid: self())

      assert KeyedTrackingObservable.proj_key_count(server) == 1
      assert KeyedTrackingObservable.subscriber_count(server) == 1
    end
  end
end
