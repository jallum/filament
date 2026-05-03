defmodule Filament.Hooks.UseHoldTest do
  use ExUnit.Case

  alias Filament.{Hooks, Fiber, RenderContext}

  # State: %{item_id => %{id: item_id, available: n}}
  defmodule TestStore do
    use Filament.Hold.GenServer

    def start_link(items \\ []) do
      GenServer.start_link(__MODULE__, items)
    end

    def init(items) do
      {:ok, Map.new(items, fn {id, qty} -> {id, %{id: id, available: qty}} end)}
    end

    def available(pid, id), do: GenServer.call(pid, {:available, id})
    def handle_call({:available, id}, _from, state), do: {:reply, state[id][:available], state}

    @impl Filament.Hold
    def handle_acquire(item_id, qty, _holder_pid, state) do
      case state[item_id] do
        %{available: a} when a >= qty ->
          {:ok, Map.update!(state, item_id, &%{&1 | available: &1.available - qty})}

        _ ->
          {:error, :insufficient, state}
      end
    end

    @impl Filament.Hold
    def handle_release(item_id, qty, _holder_pid, state) do
      {:ok, Map.update!(state, item_id, &%{&1 | available: &1.available + qty})}
    end
  end

  defmodule MinimalHoldServer do
    use Filament.Hold.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, %{})
    def init(s), do: {:ok, s}
  end

  # --- Tests ---

  test "1. first render returns {0, item, hold_fn, release_fn}" do
    store = start_supervised!({TestStore, [item: 3]})

    {held_qty, item, _hold, _release} =
      with_render_ctx("root", %{"root" => fresh_fiber()}, self(), fn ->
        Hooks.use_hold(store, :item)
      end)

    assert held_qty == 0
    assert item.available == 3
  end

  test "2. hold.(qty) decrements server availability" do
    store = start_supervised!({TestStore, [widget: 5]})

    {_held, _item, hold, _release} =
      with_render_ctx("root", %{"root" => fresh_fiber()}, self(), fn ->
        Hooks.use_hold(store, :widget)
      end)

    hold.(2)
    assert TestStore.available(store, :widget) == 3
  end

  test "3. hold raises HoldError when denied" do
    store = start_supervised!({TestStore, [scarce: 0]})

    {_held, _item, hold, _release} =
      with_render_ctx("root", %{"root" => fresh_fiber()}, self(), fn ->
        Hooks.use_hold(store, :scarce)
      end)

    assert_raise Filament.HoldError, ~r/acquisition rejected/, fn -> hold.(1) end
  end

  test "4. release.(qty) returns units to server" do
    store = start_supervised!({TestStore, [gizmo: 2]})

    {_held, _item, hold, release} =
      with_render_ctx("root", %{"root" => fresh_fiber()}, self(), fn ->
        Hooks.use_hold(store, :gizmo)
      end)

    hold.(1)
    assert TestStore.available(store, :gizmo) == 1

    # release always fires the cast; server caps at actual held qty
    release.(1)
    Process.sleep(20)
    assert TestStore.available(store, :gizmo) == 2
  end

  test "5. process death releases hold via observable unsubscribe" do
    store = start_supervised!({TestStore, [item: 2]})
    parent = self()

    holder =
      spawn(fn ->
        sub = %Filament.Observable.Subscriber{
          pid: self(),
          fiber_id: :holder,
          slot_index: 0,
          project: &Function.identity/1
        }

        {:ok, _} = Filament.Observable.subscribe(store, :item, sub)
        :ok = GenServer.call(store, {:filament_hold, :item, 1, self()})
        send(parent, :acquired)
        receive do: (:die -> :ok)
      end)

    assert_receive :acquired, 500
    assert TestStore.available(store, :item) == 1

    Process.exit(holder, :kill)
    Process.sleep(50)
    assert TestStore.available(store, :item) == 2
  end

  test "6. disconnected render returns :disconnected without acquiring" do
    store = start_supervised!({TestStore, [item: 3]})

    ctx = %RenderContext{
      fiber_id: "root",
      fiber_tree: %{"root" => fresh_fiber()},
      owner_pid: self(),
      subscribe_enabled: false
    }

    Process.put(:filament_render_context, ctx)

    result =
      try do
        Hooks.use_hold(store, :item)
      after
        Process.delete(:filament_render_context)
      end

    assert result == :disconnected
    assert TestStore.available(store, :item) == 3
  end

  test "7. minimal module compiles without custom callbacks" do
    pid = start_supervised!(%{id: MinimalHoldServer, start: {MinimalHoldServer, :start_link, []}})
    assert Process.alive?(pid)
  end

  # --- Helpers ---

  defp fresh_fiber do
    Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)
  end

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
