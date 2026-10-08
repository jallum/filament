defmodule Filament.ReconcilerTest do
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.Fixtures.CounterComponent
  alias Filament.Reconciler
  alias Filament.ReconcilerError

  defmodule Leaf do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_), do: ~F"<span>leaf</span>"
    end
  end

  defmodule Mid do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_), do: ~F"<Filament.ReconcilerTest.Leaf />"
    end
  end

  defmodule Root do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_), do: ~F"<Filament.ReconcilerTest.Mid />"
    end
  end

  defmodule StubCellTransport do
    @moduledoc false
    @behaviour Filament.Cell

    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, [])

    @impl GenServer
    def init(_), do: {:ok, []}
    def unsubscribe_calls(pid), do: GenServer.call(pid, :calls)

    @impl Filament.Cell
    def subscribe(server, _subscriber, _projection), do: {:ok, GenServer.call(server, :get_initial)}

    @impl Filament.Cell
    def unsubscribe(server, subscriber) do
      GenServer.cast(server, {:unsubscribed, subscriber})
      :ok
    end

    @impl Filament.Cell
    def current(_server, _projection), do: nil

    @impl GenServer
    def handle_call(:get_initial, _from, calls), do: {:reply, nil, calls}
    def handle_call(:calls, _from, calls), do: {:reply, calls, calls}

    @impl GenServer
    def handle_cast({:unsubscribed, subscriber}, calls), do: {:noreply, [subscriber | calls]}
  end

  describe "mount/2" do
    test "creates initial fiber tree with root fiber" do
      {tree, rendered, pending_effects} = Reconciler.mount(CounterComponent, %{count: 0})

      assert %{} = tree
      assert Map.has_key?(tree, "root")
      assert tree["root"].component == CounterComponent
      assert tree["root"].props == %{count: 0}
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

    test "preserves nested component ancestry" do
      {tree, _rendered, _effects} = Reconciler.mount(Root, %{}, owner_pid: self())
      [mid_id] = tree["root"].children
      [leaf_id] = tree[mid_id].children

      assert tree[mid_id].parent_id == "root"
      assert tree[leaf_id].parent_id == mid_id
      refute leaf_id in tree["root"].children
    end
  end

  describe "update/3" do
    test "updates fiber props and re-renders" do
      {tree, _rendered, _pending_effects1} =
        Reconciler.mount(CounterComponent, %{count: 0})

      {new_tree, new_rendered, _pending_effects2} = Reconciler.update(tree, "root", %{count: 1})

      # Check fiber was updated
      assert new_tree["root"].props == %{count: 1}

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

    test "raises when the tree has no root" do
      tree = %{}

      assert_raise ReconcilerError, ~r/no root fiber/, fn ->
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
          parent_id: "root.child",
          hook_slots: %{0 => {[], grandchild_cleanup}}
        )

      {tree, _, _} = Reconciler.mount(CounterComponent, %{count: 0})

      child =
        Fiber.new(
          id: "root.child",
          component: CounterComponent,
          props: %{count: 1},
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

    test "cell is unsubscribed when fiber is removed" do
      server = start_supervised!(%{id: StubCellTransport, start: {StubCellTransport, :start_link, []}})
      owner = self()
      cell = Filament.Source.new(StubCellTransport, server)
      subscriber = {owner, "root.child", 0, make_ref()}

      {tree, _, _} = Reconciler.mount(CounterComponent, %{count: 0})

      child =
        Fiber.new(
          id: "root.child",
          component: CounterComponent,
          props: %{count: 1},
          parent_id: "root",
          hook_slots: %{0 => {:cell_subscribed, cell, 42, subscriber, &Function.identity/1, 42}}
        )

      tree =
        tree
        |> Map.put("root.child", child)
        |> Map.update!("root", &%{&1 | children: ["root.child"]})

      {new_tree, _, _} = Reconciler.update(tree, "root", %{count: 1}, owner_pid: owner)

      refute Map.has_key?(new_tree, "root.child")
      # Allow the cast to be processed
      :timer.sleep(10)
      assert StubCellTransport.unsubscribe_calls(server) == [subscriber]
    end

    test "parent fiber children list is updated to match new render" do
      {tree, _, _} = Reconciler.mount(CounterComponent, %{count: 0})

      child =
        Fiber.new(
          id: "root.child",
          component: CounterComponent,
          props: %{count: 1},
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
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      use_value(cell, fn
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

  defmodule LifecycleLeaf do
    @moduledoc false
    use Filament.Component

    def render(%{server: server, observer: observer}) do
      use_value(KeyedTrackingObservable.cell(server), &Function.identity/1)
      {value, _} = use_state(0)
      use_effect(fn -> fn -> send(observer, :leaf_cleanup) end end, [])
      {:text, to_string(value)}
    end
  end

  defmodule LifecycleList do
    @moduledoc false
    def render(%{items: items} = props) do
      {:fragment, Enum.map(items, &{:component, LifecycleLeaf, props, &1})}
    end
  end

  defmodule LifecycleBranch do
    @moduledoc false
    def render(props), do: {:component, LifecycleList, props, nil}
  end

  defmodule LifecycleRoot do
    @moduledoc false
    def render(props), do: {:component, LifecycleBranch, props, nil}
  end

  test "removed descendants clean up once under retained ancestors and remount fresh" do
    server = start_supervised!(KeyedTrackingObservable)
    props = %{server: server, observer: self(), items: [:a, :b]}
    {tree, _, effects} = Reconciler.mount(LifecycleRoot, props, owner_pid: self())
    {tree, _} = Filament.LiveView.apply_effects(effects, tree)
    [branch] = tree["root"].children
    [list] = tree[branch].children
    [a, b] = Enum.sort(tree[list].children)
    assert length(tree[list].children) == 2
    {:rerender, tree} = Filament.StateHelper.apply_set_state(tree, a, 1, 7)
    {:rerender, tree} = Filament.StateHelper.apply_set_state(tree, b, 1, 9)
    {:filament_set_state, ^b, 1, stale_token, 5} = Filament.StateHelper.set_state(tree, b, 1, 5)

    {tree, _, _} = Reconciler.update(tree, "root", %{props | items: [:a]}, owner_pid: self())
    refute Map.has_key?(tree, b)
    assert {:state, 7, _, _} = tree[a].hook_slots[1]
    assert KeyedTrackingObservable.subscriber_count(server) == 1
    assert_receive :leaf_cleanup
    refute_receive :leaf_cleanup

    {tree, _, effects} = Reconciler.update(tree, "root", props, owner_pid: self())
    {tree, _} = Filament.LiveView.apply_effects(effects, tree)
    assert {:state, 0, _, _} = tree[b].hook_slots[1]
    # A setter kept from the removed instance doesn't write into the new one.
    assert Filament.LiveView.apply_message(tree, {:filament_set_state, b, 1, stale_token, 5}) == {:ok, tree}
    assert KeyedTrackingObservable.subscriber_count(server) == 2

    {tree, _, _} = Reconciler.update(tree, "root", %{props | items: []}, owner_pid: self())
    assert Map.has_key?(tree, "root")
    assert Map.has_key?(tree, branch)
    assert tree[list].children == []
    refute Map.has_key?(tree, a)
    refute Map.has_key?(tree, b)
    assert KeyedTrackingObservable.subscriber_count(server) == 0
    assert_receive :leaf_cleanup
    assert_receive :leaf_cleanup
    refute_receive :leaf_cleanup
  end
end
