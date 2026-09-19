defmodule Filament.Observable.CellImplTest do
  @moduledoc """
  Phase 2.2: `Filament.Observable.GenServer` implements the `Filament.Cell`
  behaviour, so a GenServer-backed observable can be addressed as a Cell
  transport: `Filament.Source.new(Filament.Observable.GenServer, server_pid_or_name)`.

  The legacy `Filament.Observable.subscribe/2` API and `notify_observers/1`
  message format stay untouched — these tests only exercise the Cell-shaped
  surface.
  """
  use ExUnit.Case, async: true

  alias Filament.Cell

  defmodule Counter do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, 0, opts)

    @impl GenServer
    def init(initial), do: {:ok, initial}

    @impl GenServer
    def handle_call(:increment, _from, count) do
      new_count = count + 1
      notify_observers(new_count)
      {:reply, new_count, new_count}
    end
  end

  describe "Cell.subscribe/3 against a GenServer-backed observable" do
    test "delivers the current projected value on subscribe" do
      {:ok, server} = Counter.start_link()
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      assert {:ok, 0} = Cell.subscribe(cell, self(), & &1)
    end

    test "applies a projection on subscribe" do
      {:ok, server} = Counter.start_link()
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      assert {:ok, "0"} = Cell.subscribe(cell, self(), &Integer.to_string/1)
    end

    test "returns :disconnected when the server isn't running" do
      cell = Filament.Source.new(Filament.Observable.GenServer, :nonexistent_server_name)
      assert :disconnected = Cell.subscribe(cell, self(), & &1)
    end
  end

  describe "Cell.current/2" do
    test "reads the current projected value without subscribing" do
      {:ok, server} = Counter.start_link()
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      assert Cell.current(cell, & &1) == 0
      GenServer.call(server, :increment)
      assert Cell.current(cell, & &1) == 1
    end

    test "returns :disconnected when the server isn't running" do
      cell = Filament.Source.new(Filament.Observable.GenServer, :nonexistent_server)
      assert Cell.current(cell, & &1) == :disconnected
    end
  end

  describe "Cell.unsubscribe/2" do
    test "is idempotent on unknown subscribers" do
      {:ok, server} = Counter.start_link()
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      assert :ok = Cell.unsubscribe(cell, :never_subscribed)
    end

    test "is idempotent when the server isn't running" do
      cell = Filament.Source.new(Filament.Observable.GenServer, :nonexistent_server)
      assert :ok = Cell.unsubscribe(cell, :anything)
    end
  end

  describe "change-or-bust delivery" do
    test "subscriber receives an update when the projection changes" do
      {:ok, server} = Counter.start_link()
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      Cell.subscribe(cell, {self(), :counter}, & &1)
      GenServer.call(server, :increment)

      assert_receive {:cell_update, {self_pid, :counter}, 1}, 200
      assert self_pid == self()
    end

    test "subscriber does NOT receive an update when projection unchanged" do
      {:ok, server} = Counter.start_link()
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      # Project to a constant — every state-change event projects to the same
      # value, so the change-or-bust filter must suppress updates.
      Cell.subscribe(cell, :const_sub, fn _ -> :always_same end)
      GenServer.call(server, :increment)
      GenServer.call(server, :increment)

      refute_receive {:cell_update, :const_sub, _}, 100
    end

    test "unsubscribed subscriber stops receiving updates" do
      {:ok, server} = Counter.start_link()
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      Cell.subscribe(cell, {self(), :unsub_test}, & &1)
      Cell.unsubscribe(cell, {self(), :unsub_test})

      GenServer.call(server, :increment)
      refute_receive {:cell_update, {_, :unsub_test}, _}, 100
    end
  end
end
