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
    def handle_call({:set, value}, _from, _count) do
      notify_observers(value)
      {:reply, :ok, value}
    end

    def handle_call(:increment, _from, count) do
      new_count = count + 1
      notify_observers(new_count)
      {:reply, new_count, new_count}
    end
  end

  defmodule ReadOnlyCounter do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link, do: GenServer.start_link(__MODULE__, %{value: 7, subscriptions: 0})

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl Filament.Observable
    def handle_subscribe(_subscriber, state) do
      {:ok, state.value, %{state | subscriptions: state.subscriptions + 1}}
    end

    @impl Filament.Observable
    def handle_current(state), do: {:ok, state.value, state}
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

    test "does not invoke the subscription callback" do
      {:ok, server} = ReadOnlyCounter.start_link()
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      assert Cell.current(cell, & &1) == 7
      assert :sys.get_state(server).subscriptions == 0
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

    test "batches updates for one owner" do
      {:ok, server} = Counter.start_link()
      cell = Filament.Source.new(Filament.Observable.GenServer, server)

      Cell.subscribe(cell, {self(), :first}, & &1)
      Cell.subscribe(cell, {self(), :second}, & &1)
      GenServer.call(server, :increment)

      assert_receive {:cell_updates, updates}, 200
      assert Enum.sort(updates) == Enum.sort([{{self(), :first}, 1}, {{self(), :second}, 1}])
      refute_receive {:cell_update, _, _}
    end
  end

  test "nil is delivered, deduplicated, and followed by non-nil updates" do
    server = start_supervised!(Counter)
    source = Counter.cell(server)
    subscriber = {self(), :nullable}
    assert {:ok, 0} = Cell.subscribe(source, subscriber, &Function.identity/1)
    GenServer.call(server, {:set, nil})
    assert_receive {:cell_update, ^subscriber, nil}
    GenServer.call(server, {:set, nil})
    refute_receive {:cell_update, _, _}
    GenServer.call(server, {:set, 3})
    assert_receive {:cell_update, ^subscriber, 3}
  end

  test "nil projection values are included in owner batches" do
    server = start_supervised!(Counter)
    source = Counter.cell(server)
    first = {self(), :nullable}
    second = {self(), :number}
    Cell.subscribe(source, first, fn n -> if n == 0, do: 0 end)
    Cell.subscribe(source, second, &Function.identity/1)
    GenServer.call(server, :increment)
    assert_receive {:cell_updates, updates}
    assert Map.new(updates) == %{first => nil, second => 1}
  end
end
