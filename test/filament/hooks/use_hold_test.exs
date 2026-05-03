defmodule Filament.Hooks.UseHoldTest do
  use ExUnit.Case

  alias Filament.{Hooks, Fiber, RenderContext}

  defmodule TestVault do
    use Filament.Hold.GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, %{held_by: []}}

    @impl Filament.Hold
    def handle_acquire({:item, id}, holder, state) do
      {:ok, {:token, id}, %{state | held_by: [{holder, id} | state.held_by]}}
    end

    @impl Filament.Hold
    def handle_release({:token, id}, holder, state) do
      {:ok, %{state | held_by: List.delete(state.held_by, {holder, id})}}
    end

    def held_by(pid), do: GenServer.call(pid, :held_by)
    def handle_call(:held_by, _from, state), do: {:reply, state.held_by, state}
  end

  defmodule MinimalHoldServer do
    use Filament.Hold.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, %{}}
  end

  defmodule RejectingVault do
    use Filament.Hold.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, :no_state}

    @impl Filament.Hold
    def handle_acquire(:reject_me, _holder, state) do
      {:error, :unavailable, state}
    end

    def handle_acquire(_request, _holder, state) do
      {:ok, make_ref(), state}
    end
  end

  # --- Tests ---

  test "1. acquire on first render" do
    vault = start_supervised!({TestVault, :ok})
    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    {token, new_slots} =
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        t = Hooks.use_hold(vault, {:item, 42})
        {t, Hooks.current_context().new_hook_slots}
      end)

    assert token == {:token, 42}
    assert new_slots[0] == {:held, vault, {:token, 42}}
  end

  test "2. stable re-render returns same token without re-acquiring" do
    vault = start_supervised!({TestVault, :ok})

    # First render
    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    token1 =
      with_render_ctx("root", %{"root" => fiber1}, self(), fn ->
        Hooks.use_hold(vault, {:item, 1})
      end)

    # Second render with existing hold
    fiber2 =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:held, vault, token1}},
        status: :stable
      )

    {token2, new_slots} =
      with_render_ctx("root", %{"root" => fiber2}, self(), fn ->
        t = Hooks.use_hold(vault, {:item, 1})
        {t, Hooks.current_context().new_hook_slots}
      end)

    assert token1 == token2
    assert new_slots[0] == {:held, vault, token1}

    # Should still be only one hold
    assert length(TestVault.held_by(vault)) == 1
  end

  test "3. server change releases old and acquires new" do
    vault_a = start_supervised!({TestVault, :ok }, id: make_ref())
    vault_b = start_supervised!({TestVault, :ok }, id: make_ref())

    # First render: acquire from vault_a
    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    _ =
      with_render_ctx("root", %{"root" => fiber1}, self(), fn ->
        Hooks.use_hold(vault_a, {:item, 1})
      end)

    assert length(TestVault.held_by(vault_a)) == 1

    # Second render: switch to vault_b
    fiber2 =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:held, vault_a, {:token, 1}}},
        status: :stable
      )

    token_b =
      with_render_ctx("root", %{"root" => fiber2}, self(), fn ->
        Hooks.use_hold(vault_b, {:item, 2})
      end)

    assert token_b == {:token, 2}

    # vault_a should have released, vault_b should have acquired
    Process.sleep(50)
    assert TestVault.held_by(vault_a) == []
    assert length(TestVault.held_by(vault_b)) == 1
  end

  test "4. rejection raises HoldError" do
    rejecting = start_supervised!(%{id: RejectingVault, start: {RejectingVault, :start_link, []}})

    fiber = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    assert_raise Filament.HoldError, ~r/acquisition rejected/, fn ->
      with_render_ctx("root", %{"root" => fiber}, self(), fn ->
        Hooks.use_hold(rejecting, :reject_me)
      end)
    end
  end

  test "5. unmount releases hold" do
    vault = start_supervised!({TestVault, :ok})

    # First render: acquire
    fiber1 = Fiber.new(id: "root", component: nil, hook_slots: %{}, status: :stable)

    _ =
      with_render_ctx("root", %{"root" => fiber1}, self(), fn ->
        Hooks.use_hold(vault, {:item, 1})
      end)

    assert length(TestVault.held_by(vault)) == 1

    # Unmount
    fiber2 =
      Fiber.new(
        id: "root",
        component: nil,
        hook_slots: %{0 => {:held, vault, {:token, 1}}},
        status: :stable
      )

    tree = %{"root" => fiber2}
    :ok = Filament.Reconciler.unmount(tree, owner_pid: self())

    Process.sleep(50)
    assert TestVault.held_by(vault) == []
  end

  test "6. DOWN releases on server side" do
    vault = start_supervised!({TestVault, :ok})

    # Spawn a temporary process that acquires a hold
    holder = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, token} = Filament.Hold.acquire(vault, {:item, 99}, holder)
    assert token == {:token, 99}
    assert length(TestVault.held_by(vault)) == 1

    # Kill the holder process
    Process.exit(holder, :kill)
    Process.sleep(50)

    # The vault should have released the hold via :DOWN
    assert TestVault.held_by(vault) == []
  end

  test "7. multiple holders independent" do
    vault = start_supervised!({TestVault, :ok})

    holder_a = spawn(fn -> Process.sleep(:infinity) end)
    holder_b = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, _token_a} = Filament.Hold.acquire(vault, {:item, 1}, holder_a)
    {:ok, _token_b} = Filament.Hold.acquire(vault, {:item, 2}, holder_b)

    assert length(TestVault.held_by(vault)) == 2

    # Kill holder_a
    Process.exit(holder_a, :kill)
    Process.sleep(50)

    # holder_b's hold should still be intact
    assert length(TestVault.held_by(vault)) == 1
    assert [{^holder_b, 2}] = TestVault.held_by(vault)

    Process.exit(holder_b, :kill)
  end

  test "8. minimal module compiles without custom callbacks" do
    pid = start_supervised!(%{id: MinimalHoldServer, start: {MinimalHoldServer, :start_link, []}})
    assert Process.alive?(pid)
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
