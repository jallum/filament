defmodule Filament.Hooks.UseObservableTest do
  use ExUnit.Case

  alias Filament.Fiber
  alias Filament.Hooks
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

  defmodule AlwaysRejectingObservable do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, :ok}

    @impl Filament.Observable
    def handle_subscribe(_request, _subscriber, state), do: {:error, :not_allowed, state}
  end

  # --- use_observable/2 (positional fn) tests ---

  test "1. initial subscription returns projected value" do
    observable = start_supervised!({TestObservable, 42})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    {value, new_slots} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        v =
          Hooks.use_observable(observable, fn
            :disconnected -> nil
            s -> s
          end)

        {v, Hooks.current_context().new_hook_slots}
      end)

    assert value == 42
    assert new_slots[0] == {:subscribed, observable, nil, 42}
  end

  test "2. stable re-render returns stored value without re-subscribing" do
    observable = start_supervised!({TestObservable, 10})

    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    with_render_ctx("root", %{"root" => fiber1}, self(), fn ->
      Hooks.use_observable(observable, fn
        :disconnected -> nil
        s -> s
      end)
    end)

    fiber2 =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:subscribed, observable, nil, 10}},
        status: :stable
      )

    {value2, new_slots} =
      with_render_ctx("root", %{"root" => fiber2}, self(), fn ->
        v =
          Hooks.use_observable(observable, fn
            :disconnected -> nil
            s -> s
          end)

        {v, Hooks.current_context().new_hook_slots}
      end)

    assert value2 == 10
    assert new_slots[0] == {:subscribed, observable, nil, 10}

    # Same {self(), nil} subscriber — still only one entry
    subs = TestObservable.get_subs(observable)
    assert subs.count == 1
  end

  test "3. server change removes old projection and subscribes to new" do
    obs_a = start_supervised!({TestObservable, 1}, id: make_ref())
    obs_b = start_supervised!({TestObservable, 2}, id: make_ref())

    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:subscribed, obs_a, nil, 1}},
        status: :stable
      )

    value =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_observable(obs_b, fn
          :disconnected -> nil
          s -> s
        end)
      end)

    assert value == 2

    # Give the async remove_projection cast time to process
    _ = TestObservable.get_subs(obs_a)
    assert TestObservable.get_subs(obs_a).count == 0
  end

  test "4. observable update via hook_slots — returns existing value" do
    observable = start_supervised!({TestObservable, 100})

    fiber =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:subscribed, observable, nil, 555}},
        status: :stable
      )

    value =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_observable(observable, fn
          :disconnected -> nil
          s -> s
        end)
      end)

    assert value == 555
  end

  test "5. subscription rejection raises ObservableError" do
    rejecting =
      start_supervised!(%{
        id: AlwaysRejectingObservable,
        start: {AlwaysRejectingObservable, :start_link, []}
      })

    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    assert_raise Filament.ObservableError, ~r/subscription rejected/, fn ->
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_observable(rejecting, fn
          :disconnected -> nil
          s -> s
        end)
      end)
    end
  end

  test "6. unmount triggers projection removal" do
    observable = start_supervised!({TestObservable, 42})

    sub = %Filament.Observable.Subscriber{
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
        hook_slots: %{0 => {:subscribed, observable, nil, 42}},
        status: :stable
      )

    :ok = Filament.Reconciler.unmount(%{"root" => fiber}, owner_pid: self())

    # Flush the async remove_projection cast
    _ = TestObservable.get_subs(observable)
    assert TestObservable.get_subs(observable).count == 0
  end

  test "7. live observable update received as batched message" do
    observable = start_supervised!({TestObservable, 1})
    me = self()
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    with_render_ctx("root", %{"root" => fiber}, me, fn ->
      Hooks.use_observable(observable, fn
        :disconnected -> nil
        s -> s
      end)
    end)

    send(me, {:filament_observable_updates, [{"root", 0, 99}]})

    assert_receive {:filament_observable_updates, [{"root", 0, 99}]}, 100
  end

  test "8. disconnected — fn called with :disconnected atom" do
    observable = start_supervised!({TestObservable, 42})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    value =
      with_render_ctx(
        "root",
        %{"root" => fiber},
        self(),
        fn ->
          Hooks.use_observable(observable, fn
            :disconnected -> :gone
            s -> s
          end)
        end,
        subscribe_enabled: false
      )

    assert value == :gone
  end

  test "9. projection fn applied to initial state on first render" do
    observable = start_supervised!({TestObservable, 100})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    value =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_observable(observable, fn
          :disconnected -> 0
          n -> n * 2
        end)
      end)

    assert value == 200
  end

  test "10. two use_observable/2 calls on same server share one subscriber entry" do
    observable = start_supervised!({TestObservable, 42})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    {count, total} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        c =
          Hooks.use_observable(observable, fn
            :disconnected -> 0
            s -> s
          end)

        t =
          Hooks.use_observable(observable, fn
            :disconnected -> 0
            s -> s * 10
          end)

        {c, t}
      end)

    assert count == 42
    assert total == 420
    assert TestObservable.get_subs(observable).count == 1
  end

  # --- use_observable/1 tests ---

  test "11. use_observable/1 returns pid when connected" do
    observable = start_supervised!({TestObservable, 42})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    {server, new_slots} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        s = Hooks.use_observable(observable)
        {s, Hooks.current_context().new_hook_slots}
      end)

    assert server == observable
    assert new_slots[0] == {:resolved, observable}
  end

  test "12. use_observable/1 returns nil when disconnected" do
    observable = start_supervised!({TestObservable, 42})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    server =
      with_render_ctx(
        "root",
        %{"root" => fiber},
        self(),
        fn -> Hooks.use_observable(observable) end,
        subscribe_enabled: false
      )

    assert server == nil
  end

  test "13. use_observable/1 with factory fn reuses pid if alive on re-render" do
    observable = start_supervised!({TestObservable, 0})
    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    pid1 =
      with_render_ctx("root", %{"root" => fiber1}, self(), fn ->
        Hooks.use_observable(fn -> observable end)
      end)

    assert pid1 == observable

    fiber2 =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:resolved, pid1}},
        status: :stable
      )

    pid2 =
      with_render_ctx("root", %{"root" => fiber2}, self(), fn ->
        Hooks.use_observable(fn -> observable end)
      end)

    assert pid2 == pid1
  end

  # --- Helpers ---

  defp with_render_ctx(fiber_id, fiber_tree, owner_pid, fun, extra_opts \\ []) do
    ctx = %RenderContext{
      fiber_id: fiber_id,
      fiber_tree: fiber_tree,
      owner_pid: owner_pid,
      subscribe_enabled: Keyword.get(extra_opts, :subscribe_enabled, true)
    }

    Process.put(:filament_render_context, ctx)

    try do
      fun.()
    after
      Process.delete(:filament_render_context)
    end
  end
end
