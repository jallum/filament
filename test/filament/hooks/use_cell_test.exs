defmodule Filament.Hooks.UseCellTest do
  @moduledoc """
  Phase 2.3: `use_cell(cell, projection)` is the generic cell-subscription
  hook. It accepts any `Filament.Cell` tuple — GenServer-backed observable,
  in-process struct, focus tracker, etc. — and projects the current value
  for the calling fiber. The component is unaware of the transport.

  The hook subscribes with identity projection (delivers raw cell values)
  and applies the user's projection at render time, mirroring
  `use_observable`'s closure-freshness semantics. Cell's change-or-bust
  fires on raw value changes; render-level projection then determines
  whether the diff engine has anything to send.
  """
  use ExUnit.Case, async: true

  alias Filament.FiberTree
  alias Filament.Reconciler

  defmodule Counter do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link(initial \\ 0), do: GenServer.start_link(__MODULE__, initial, [])
    def increment(server), do: GenServer.call(server, :increment)

    @impl GenServer
    def init(initial), do: {:ok, initial}

    @impl GenServer
    def handle_call(:increment, _from, count) do
      new_count = count + 1
      notify_observers(new_count)
      {:reply, new_count, new_count}
    end
  end

  defmodule CellComp do
    @moduledoc false
    use Filament.Component

    defcomponent CellComp do
      prop(:cell, :any, required: true)

      def render(%{cell: cell}) do
        count = use_cell(cell, & &1)
        ~F"<p>{count}</p>"
      end
    end
  end

  describe "use_cell/2" do
    test "delivers the initial projected value on first mount" do
      {:ok, server} = Counter.start_link(7)
      cell = {Filament.Observable.GenServer, server}

      {tree, walked, _} =
        Reconciler.mount(CellComp.CellComp, %{cell: cell}, owner_pid: self())

      html = walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "<p>7</p>"
      assert tree["root"].hook_slots != %{}
    end

    test "applies the projection function on render" do
      {:ok, server} = Counter.start_link(5)
      cell = {Filament.Observable.GenServer, server}

      defmodule ProjectedComp do
        use Filament.Component

        defcomponent ProjectedComp do
          prop(:cell, :any, required: true)

          def render(%{cell: cell}) do
            doubled = use_cell(cell, &(&1 * 2))
            ~F"<p>{doubled}</p>"
          end
        end
      end

      {_tree, walked, _} =
        Reconciler.mount(ProjectedComp.ProjectedComp, %{cell: cell}, owner_pid: self())

      assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>10</p>"
    end

    test "cell update sends a message scoped to the subscribing fiber" do
      {:ok, server} = Counter.start_link(0)
      cell = {Filament.Observable.GenServer, server}

      Reconciler.mount(CellComp.CellComp, %{cell: cell}, owner_pid: self())

      Counter.increment(server)
      assert_receive {:cell_update, {pid, "root", 0}, 1}, 200
      assert pid == self()
    end

    test "use_cell returns :disconnected projection when the cell is unreachable" do
      cell = {Filament.Observable.GenServer, :nonexistent_server}

      defmodule DisconnectedComp do
        use Filament.Component

        defcomponent DisconnectedComp do
          prop(:cell, :any, required: true)

          def render(%{cell: cell}) do
            value =
              use_cell(cell, fn
                :disconnected -> "no-server"
                v -> "v=#{v}"
              end)

            ~F"<p>{value}</p>"
          end
        end
      end

      {_tree, walked, _} =
        Reconciler.mount(DisconnectedComp.DisconnectedComp, %{cell: cell}, owner_pid: self())

      assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>no-server</p>"
    end
  end

  describe "subscribe_enabled = false (HTTP static mount)" do
    test "use_cell returns :disconnected projection during static render" do
      {:ok, server} = Counter.start_link(42)
      cell = {Filament.Observable.GenServer, server}

      defmodule StaticComp do
        use Filament.Component

        defcomponent StaticComp do
          prop(:cell, :any, required: true)

          def render(%{cell: cell}) do
            value =
              use_cell(cell, fn
                :disconnected -> "no-server"
                v -> "v=#{v}"
              end)

            ~F"<p>{value}</p>"
          end
        end
      end

      {_tree, walked, _} =
        Reconciler.mount(StaticComp.StaticComp, %{cell: cell},
          owner_pid: self(),
          connected: false
        )

      assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>no-server</p>"
    end
  end

  describe "use_cell + Reconciler.update reflect cell changes" do
    test "re-render after cell update reads the latest value via fiber slot" do
      {:ok, server} = Counter.start_link(0)
      cell = {Filament.Observable.GenServer, server}

      {tree1, walked1, _} =
        Reconciler.mount(CellComp.CellComp, %{cell: cell}, owner_pid: self())

      assert walked1 |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>0</p>"

      Counter.increment(server)
      assert_receive {:cell_update, {_, fid, sid}, 1}, 200

      tree2 =
        FiberTree.update_hook_slot(tree1, fid, sid, fn _ -> {:cell_subscribed, cell, 1} end)

      {_, walked3, _} =
        Reconciler.update(tree2, "root", %{cell: cell}, owner_pid: self())

      assert walked3 |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>1</p>"
    end

    test "swapping the cell across renders unsubscribes from the old transport" do
      {:ok, server_a} = Counter.start_link(10)
      {:ok, server_b} = Counter.start_link(20)
      cell_a = {Filament.Observable.GenServer, server_a}
      cell_b = {Filament.Observable.GenServer, server_b}

      {tree1, walked1, _} =
        Reconciler.mount(CellComp.CellComp, %{cell: cell_a}, owner_pid: self())

      assert walked1 |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>10</p>"

      # Sanity: server_a has one cell subscriber.
      cell_subs_a = :sys.get_state(server_a) && cell_subscribers_in(server_a)
      assert map_size(cell_subs_a) == 1

      # Re-render with a different cell — slot should detect the swap and
      # transition to subscribing on cell_b.
      {_tree2, walked2, _} =
        Reconciler.update(tree1, "root", %{cell: cell_b}, owner_pid: self())

      assert walked2 |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>20</p>"

      # server_a now has zero subscribers; server_b has one.
      assert cell_subscribers_in(server_a) |> map_size() == 0
      assert cell_subscribers_in(server_b) |> map_size() == 1
    end
  end

  describe "use_cell/1 (factory form)" do
    defmodule FactoryCellComp do
      @moduledoc false
      use Filament.Component

      defcomponent FactoryCellComp do
        prop(:server, :any, required: true)

        def render(%{server: server}) do
          cell = use_cell(fn -> {Filament.Observable.GenServer, server} end)
          count = use_cell(cell, & &1)
          ~F"<p>{count}</p>"
        end
      end
    end

    test "factory fn resolves to a cell tuple and feeds use_cell/2" do
      {:ok, server} = Counter.start_link(3)

      {_tree, walked, _} =
        Reconciler.mount(FactoryCellComp.FactoryCellComp, %{server: server},
          owner_pid: self()
        )

      assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>3</p>"
    end

    test "subsequent renders reuse the cached cell when the transport is alive" do
      {:ok, server} = Counter.start_link(0)

      counter = :counters.new(1, [])
      factory = fn ->
        :counters.add(counter, 1, 1)
        {Filament.Observable.GenServer, server}
      end

      defmodule SpyComp do
        use Filament.Component

        defcomponent SpyComp do
          prop(:factory, :any, required: true)

          def render(%{factory: factory}) do
            cell = use_cell(factory)
            count = use_cell(cell, & &1)
            ~F"<p>{count}</p>"
          end
        end
      end

      {tree1, _, _} =
        Reconciler.mount(SpyComp.SpyComp, %{factory: factory}, owner_pid: self())

      {_tree2, _, _} =
        Reconciler.update(tree1, "root", %{factory: factory}, owner_pid: self())

      # Factory called only once across the two renders.
      assert :counters.get(counter, 1) == 1
    end

    test "factory is re-called when the cached transport pid is dead" do
      {:ok, server1} = Counter.start_link(0)

      counter = :counters.new(1, [])

      pid_ref = :persistent_term.put({__MODULE__, :pid_ref}, server1)
      _ = pid_ref

      factory = fn ->
        :counters.add(counter, 1, 1)
        pid = :persistent_term.get({__MODULE__, :pid_ref})
        {Filament.Observable.GenServer, pid}
      end

      defmodule LiveSpyComp do
        use Filament.Component

        defcomponent LiveSpyComp do
          prop(:factory, :any, required: true)

          def render(%{factory: factory}) do
            cell = use_cell(factory)
            count = use_cell(cell, & &1)
            ~F"<p>{count}</p>"
          end
        end
      end

      {tree1, _, _} =
        Reconciler.mount(LiveSpyComp.LiveSpyComp, %{factory: factory}, owner_pid: self())

      assert :counters.get(counter, 1) == 1

      # Kill the original server, then swap in a fresh one for the factory to find.
      Process.flag(:trap_exit, true)
      Process.exit(server1, :kill)
      Process.sleep(20)

      {:ok, server2} = Counter.start_link(99)
      :persistent_term.put({__MODULE__, :pid_ref}, server2)

      {_tree2, walked, _} =
        Reconciler.update(tree1, "root", %{factory: factory}, owner_pid: self())

      # Factory called a second time because cached pid was dead.
      assert :counters.get(counter, 1) == 2
      assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>99</p>"
    end

    test "passing a cell tuple directly returns it unchanged" do
      {:ok, server} = Counter.start_link(42)
      cell = {Filament.Observable.GenServer, server}

      defmodule PassthroughComp do
        use Filament.Component

        defcomponent PassthroughComp do
          prop(:cell, :any, required: true)

          def render(%{cell: cell}) do
            resolved = use_cell(cell)
            value = use_cell(resolved, & &1)
            ~F"<p>{value}</p>"
          end
        end
      end

      {_tree, walked, _} =
        Reconciler.mount(PassthroughComp.PassthroughComp, %{cell: cell}, owner_pid: self())

      assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>42</p>"
    end
  end

  defp cell_subscribers_in(server) do
    {:dictionary, dict} = Process.info(server, :dictionary)
    Keyword.get(dict, :__filament_cell_subscribers__, %{})
  end

  describe "use_observable backward compatibility" do
    test "existing use_observable hook continues to work alongside use_cell" do
      defmodule MixedComp do
        use Filament.Component

        defcomponent MixedComp do
          def render(_assigns) do
            server = use_observable(fn -> Counter.start_link(11) end)
            count = use_observable(server, &(&1 + 1))
            ~F"<p>{count}</p>"
          end
        end
      end

      {_tree, walked, _} =
        Reconciler.mount(MixedComp.MixedComp, %{}, owner_pid: self())

      assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~ "<p>12</p>"
    end
  end
end
