defmodule Filament.Hooks.UseProjectionTest do
  use ExUnit.Case

  alias Filament.Fiber
  alias Filament.Hooks
  alias Filament.Observable.Subscriber
  alias Filament.RenderContext

  defmodule TestObservable do
    @moduledoc false
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
      {:reply, %{count: map_size(subs), keys: Map.keys(subs)}, state}
    end
  end

  defmodule RejectingObservable do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, :ok}

    @impl Filament.Observable
    def handle_subscribe(:reject_me, _subscriber, state), do: {:error, :not_allowed, state}
    def handle_subscribe(_request, _subscriber, state), do: {:ok, state, state}
  end

  # --- Tests ---

  test "1. nil server returns disconnected value" do
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    value =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_projection(nil, & &1)
      end)

    assert value == :disconnected
  end

  test "2. nil server returns custom disconnected value" do
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    value =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_projection(nil, & &1, disconnected: 0)
      end)

    assert value == 0
  end

  test "3. first render subscribes and returns projected initial value" do
    observable = start_supervised!({TestObservable, 42})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    {value, new_slots} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        v = Hooks.use_projection(observable, fn n -> n * 2 end)
        {v, Hooks.current_context().new_hook_slots}
      end)

    assert value == 84
    assert new_slots[0] == {:projected, observable, nil, 84}
  end

  test "4. re-render with same server reads from hook slot" do
    observable = start_supervised!({TestObservable, 10})

    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:projected, observable, nil, 999}},
        status: :stable
      )

    {value, new_slots} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        v = Hooks.use_projection(observable, fn n -> n * 2 end)
        {v, Hooks.current_context().new_hook_slots}
      end)

    assert value == 999
    assert new_slots[0] == {:projected, observable, nil, 999}
    # No extra subscription created
    assert TestObservable.get_subs(observable).count == 0
  end

  test "5. server change removes old projection and subscribes to new" do
    obs_a = start_supervised!({TestObservable, 1}, id: make_ref())
    obs_b = start_supervised!({TestObservable, 5}, id: make_ref())

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"root", 0} => {& &1, :unset}}
    }

    {:ok, _} = Filament.Observable.subscribe(obs_a, nil, sub)
    assert TestObservable.get_subs(obs_a).count == 1

    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:projected, obs_a, nil, 1}},
        status: :stable
      )

    value =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_projection(obs_b, & &1)
      end)

    assert value == 5

    # Flush the cast and confirm obs_a has no subscribers
    _ = TestObservable.get_subs(obs_a)
    assert TestObservable.get_subs(obs_a).count == 0
  end

  test "6. subscription rejection raises ObservableError" do
    rejecting =
      start_supervised!(%{id: RejectingObservable, start: {RejectingObservable, :start_link, []}})

    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    assert_raise Filament.ObservableError, ~r/subscription rejected/, fn ->
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_projection(rejecting, & &1, request: :reject_me)
      end)
    end
  end

  test "7. unmount removes projection from server" do
    observable = start_supervised!({TestObservable, 42})

    sub = %Subscriber{
      pid: self(),
      request: nil,
      projections: %{{"root", 0} => {& &1, :unset}}
    }

    {:ok, _} = Filament.Observable.subscribe(observable, nil, sub)
    assert TestObservable.get_subs(observable).count == 1

    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:projected, observable, nil, 42}},
        status: :stable
      )

    :ok = Filament.Reconciler.unmount(%{"root" => fiber}, owner_pid: self())

    _ = TestObservable.get_subs(observable)
    assert TestObservable.get_subs(observable).count == 0
  end

  test "8. multiple use_projections on same server share one subscriber" do
    observable = start_supervised!({TestObservable, 10})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    {val_a, val_b} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        a = Hooks.use_projection(observable, fn n -> n + 1 end)
        b = Hooks.use_projection(observable, fn n -> n * 10 end)
        {a, b}
      end)

    assert val_a == 11
    assert val_b == 100
    # Both projections share one subscriber entry on the server
    assert TestObservable.get_subs(observable).count == 1
  end

  test "9. batched update message applies to {:projected, ...} slot" do
    observable = start_supervised!({TestObservable, 5})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    with_render_ctx("root", %{"root" => fiber}, self(), fn ->
      Hooks.use_projection(observable, fn n -> n * 2 end)
    end)

    # Simulate what the server sends after notify_observers
    tree = %{
      "root" =>
        Fiber.new(
          id: "root",
          component: nil,
          hook_slots: %{0 => {:projected, observable, nil, 10}},
          status: :stable
        )
    }

    updates = [{"root", 0, 20}]
    new_tree = Filament.LiveView.apply_observable_updates(tree, updates)

    assert {:projected, ^observable, nil, 20} = new_tree["root"].hook_slots[0]
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
