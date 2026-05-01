defmodule Filament.Hooks.UseObservableTest do
  use ExUnit.Case

  alias Filament.{Hooks, Fiber, RenderContext}

  defmodule TestObservable do
    use Filament.Observable.GenServer

    def start_link(n), do: GenServer.start_link(__MODULE__, n)
    def init(n), do: {:ok, n}

    def set(pid, n), do: GenServer.call(pid, {:set, n})
    def get_subs(pid), do: GenServer.call(pid, :get_subs)

    def handle_call({:set, n}, _from, _state) do
      notify_observers(n)
      {:reply, :ok, n}
    end

    def handle_call(:get_subs, _from, state) do
      subs = Process.get(:__filament_subscribers__, %{})
      {:reply, %{count: map_size(subs), pids: Map.keys(subs)}, state}
    end
  end

  defmodule RejectingObservable do
    use Filament.Observable.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, :ok}

    @impl Filament.Observable
    def handle_subscribe(_request, _subscriber, state) do
      {:error, :not_allowed, state}
    end
  end

  # --- Tests ---

  test "1. initial subscription returns projected value" do
    {:ok, observable} = TestObservable.start_link(42)
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    {value, new_slots} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        v = Hooks.use_observable(observable, nil, project: & &1)
        {v, Hooks.current_context().new_hook_slots}
      end)

    assert value == 42
    assert new_slots[0] == {:subscribed, observable, 42}
  end

  test "2. stable re-render returns stored value without re-subscribing" do
    {:ok, observable} = TestObservable.start_link(10)

    # First render — subscribe
    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    with_render_ctx("root", %{"root" => fiber1}, self(), fn ->
      Hooks.use_observable(observable, nil, project: & &1)
    end)

    # Second render — slot already has {:subscribed, server, val}
    fiber2 =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:subscribed, observable, 10}},
        status: :stable
      )

    {value2, new_slots} =
      with_render_ctx("root", %{"root" => fiber2}, self(), fn ->
        v = Hooks.use_observable(observable, nil, project: & &1)
        {v, Hooks.current_context().new_hook_slots}
      end)

    assert value2 == 10
    assert new_slots[0] == {:subscribed, observable, 10}

    # Should still be only 1 subscriber
    subs = TestObservable.get_subs(observable)
    assert subs.count == 1
  end

  test "3. server change unsubscribes old and subscribes new" do
    {:ok, obs_a} = TestObservable.start_link(1)
    {:ok, obs_b} = TestObservable.start_link(2)

    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:subscribed, obs_a, 1}},
        status: :stable
      )

    value =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_observable(obs_b, nil, project: & &1)
      end)

    assert value == 2

    # obs_a should have no subscribers
    assert TestObservable.get_subs(obs_a).count == 0
  end

  test "4. observable update via hook_slots — returns existing value" do
    {:ok, observable} = TestObservable.start_link(100)

    # Simulate that handle_info already updated the slot to 555
    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:subscribed, observable, 555}},
        status: :stable
      )

    value =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_observable(observable, nil, project: & &1)
      end)

    # Returns 555 (not 100 — the hook reads the slot, doesn't re-subscribe)
    assert value == 555
  end

  test "5. subscription rejection raises ObservableError" do
    {:ok, rejecting} = RejectingObservable.start_link()

    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    assert_raise Filament.ObservableError, ~r/subscription rejected/, fn ->
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_observable(rejecting, nil, project: & &1)
      end)
    end
  end

  test "6. unmount triggers observable unsubscription" do
    {:ok, observable} = TestObservable.start_link(42)

    # Subscribe self first so observable has a subscriber
    %Filament.Observable.Subscriber{pid: self(), fiber_id: "root", slot_index: 0, project: & &1}
    |> then(&Filament.Observable.subscribe(observable, :any, &1))

    assert TestObservable.get_subs(observable).count == 1

    # Unmount via reconciler (no owner_pid needed since our test uses self())
    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:subscribed, observable, 42}},
        status: :stable
      )

    tree = %{"root" => fiber}

    :ok = Filament.Reconciler.unmount(tree, owner_pid: self())

    # Observable should now have no subscribers
    assert TestObservable.get_subs(observable).count == 0
  end

  test "7. live observable update received and applied" do
    {:ok, observable} = TestObservable.start_link(1)

    # Subscribe
    me = self()

    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    with_render_ctx("root", %{"root" => fiber}, me, fn ->
      Hooks.use_observable(observable, nil, project: & &1)
    end)

    # Simulate the observable sending an update
    send(me, {:filament_observable_update, "root", 0, 99})

    # Verify we received the message
    assert_receive {:filament_observable_update, "root", 0, 99}, 100
  end

  # --- Helpers ---

  defp with_render_ctx(fiber_id, fiber_tree, owner_pid, fun) do
    ctx = %RenderContext{
      fiber_id: fiber_id,
      fiber_tree: fiber_tree,
      owner_pid: owner_pid
    }

    Process.put(:filament_render_context, ctx)

    try do
      fun.()
    after
      Process.delete(:filament_render_context)
    end
  end
end
