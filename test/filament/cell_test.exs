defmodule Filament.CellTest do
  @moduledoc """
  Phase 2.1: `Filament.Cell` defines the contract every reactivity transport
  implements. A cell is a tagged tuple `{transport_module, transport_data}`;
  the dispatch helpers in `Filament.Cell` route the call to the transport.

  These tests exercise the contract with a tiny in-memory test transport
  (`TestCell`), independent of any real implementation. The same contract
  is what `Filament.Observable.GenServer` and any future transport will
  satisfy.
  """
  use ExUnit.Case, async: true

  alias Filament.Cell

  defmodule TestCell do
    @moduledoc """
    Synchronous in-process cell for tests. Backed by an Agent so values are
    stored across processes; subscriber notifications fire by calling
    `send(subscriber_pid, {:cell_update, projected_value})` on broadcast.

    The agent state shape:
        %{
          value: term(),
          subscribers: %{subscriber => {pid, projection_fn, last_projected}}
        }
    """

    @behaviour Cell

    use Agent

    def start_link(initial_value) do
      Agent.start_link(fn ->
        %{value: initial_value, subscribers: %{}}
      end)
    end

    @impl true
    def subscribe(agent, subscriber, projection_fn) when is_function(projection_fn, 1) do
      pid = self()

      Agent.get_and_update(agent, fn state ->
        projected = projection_fn.(state.value)

        new_subs =
          Map.put(state.subscribers, subscriber, {pid, projection_fn, projected})

        {{:ok, projected}, %{state | subscribers: new_subs}}
      end)
    end

    @impl true
    def unsubscribe(agent, subscriber) do
      Agent.update(agent, fn state ->
        %{state | subscribers: Map.delete(state.subscribers, subscriber)}
      end)
    end

    @impl true
    def current(agent, projection_fn) when is_function(projection_fn, 1) do
      Agent.get(agent, fn state -> projection_fn.(state.value) end)
    end

    @doc "Test-only helper: write a new value and notify subscribers."
    def write(agent, new_value) do
      Agent.update(agent, fn state ->
        new_subs = Map.new(state.subscribers, &reproject_subscriber(&1, new_value))
        %{state | value: new_value, subscribers: new_subs}
      end)
    end

    defp reproject_subscriber({sub, {pid, projection_fn, last_projected}}, new_value) do
      new_projected = projection_fn.(new_value)

      if new_projected != last_projected do
        send(pid, {:cell_update, sub, new_projected})
      end

      {sub, {pid, projection_fn, new_projected}}
    end
  end

  describe "Cell.subscribe/3" do
    test "returns the current projected value" do
      {:ok, agent} = TestCell.start_link(%{count: 5})
      cell = {TestCell, agent}

      assert {:ok, 5} = Cell.subscribe(cell, :sub_a, & &1.count)
    end

    test "different subscribers can use different projections" do
      {:ok, agent} = TestCell.start_link(%{count: 5, name: "alice"})
      cell = {TestCell, agent}

      assert {:ok, 5} = Cell.subscribe(cell, :a, & &1.count)
      assert {:ok, "alice"} = Cell.subscribe(cell, :b, & &1.name)
    end
  end

  describe "Cell.current/2" do
    test "reads the current projected value without subscribing" do
      {:ok, agent} = TestCell.start_link(%{count: 7})
      cell = {TestCell, agent}

      assert Cell.current(cell, & &1.count) == 7
      # No subscriber should have been added.
      assert :ok = Cell.unsubscribe(cell, :nobody)
    end
  end

  describe "Cell.unsubscribe/2" do
    test "stops further updates from reaching the subscriber" do
      {:ok, agent} = TestCell.start_link(%{count: 0})
      cell = {TestCell, agent}

      Cell.subscribe(cell, :sub, & &1.count)
      Cell.unsubscribe(cell, :sub)

      TestCell.write(agent, %{count: 1})
      refute_receive {:cell_update, :sub, _}, 50
    end

    test "is idempotent on unknown subscribers" do
      {:ok, agent} = TestCell.start_link(%{})
      cell = {TestCell, agent}

      assert :ok = Cell.unsubscribe(cell, :never_subscribed)
    end
  end

  describe "change-or-bust notification" do
    test "subscriber receives an update when the projection changes" do
      {:ok, agent} = TestCell.start_link(%{count: 0, name: "alice"})
      cell = {TestCell, agent}

      Cell.subscribe(cell, :counter, & &1.count)

      TestCell.write(agent, %{count: 1, name: "alice"})
      assert_receive {:cell_update, :counter, 1}, 100
    end

    test "subscriber does NOT receive an update when projection unchanged" do
      {:ok, agent} = TestCell.start_link(%{count: 0, name: "alice"})
      cell = {TestCell, agent}

      Cell.subscribe(cell, :name_only, & &1.name)

      # Underlying value changes but the projection is stable.
      TestCell.write(agent, %{count: 99, name: "alice"})
      refute_receive {:cell_update, :name_only, _}, 50
    end
  end
end
