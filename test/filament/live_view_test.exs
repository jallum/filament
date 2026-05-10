defmodule Filament.LiveViewTest do
  use ExUnit.Case, async: false

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  # Helper: create a socket with proper lifecycle structures for attach_hook
  defp test_socket(assigns) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      private: %{
        live_temp: %{},
        lifecycle: Lifecycle.__struct__()
      }
    }
  end

  # Define test modules inline
  defmodule CounterComponent do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:count, :integer, required: true)

      def render(assigns) do
        ~F"""
        <div class="counter">
          <h1>Counter: {@count}</h1>
        </div>
        """
      end
    end
  end

  defmodule CounterLiveView do
    use Filament.LiveView

    def root_component, do: CounterComponent
  end

  describe "module injection" do
    test "injects mount/3 function" do
      assert function_exported?(CounterLiveView, :mount, 3)
    end

    test "injects render/1 function" do
      assert function_exported?(CounterLiveView, :render, 1)
    end

    test "injects handle_event/3 function" do
      assert function_exported?(CounterLiveView, :handle_event, 3)
    end

    test "injects handle_info/2 function" do
      assert function_exported?(CounterLiveView, :handle_info, 2)
    end
  end

  describe "behaviour" do
    test "implements root_component/0 callback" do
      assert function_exported?(CounterLiveView, :root_component, 0)
      assert CounterLiveView.root_component() == CounterComponent
    end
  end

  describe "render/1" do
    test "returns valid Phoenix.LiveView.Rendered struct" do
      # Simulate mount
      socket = test_socket(%{count: 5})

      {:ok, socket} = CounterLiveView.mount(%{}, %{}, socket)

      rendered = CounterLiveView.render(socket.assigns)
      assert %Rendered{} = rendered

      # Convert to HTML and verify
      html = rendered |> Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "Counter: 5"
    end

    test "rendered html contains no filament debug artifacts" do
      socket = test_socket(%{count: 0})

      {:ok, socket} = CounterLiveView.mount(%{}, %{}, socket)

      rendered = CounterLiveView.render(socket.assigns)
      html = rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()

      refute html =~ ~r/filament:[a-z0-9_]+:\d+/
      refute html =~ ~r/_filament/
    end
  end

  describe "mount/3" do
    test "assigns _filament_tree and _filament_rendered" do
      socket = test_socket(%{count: 0})

      {:ok, socket} = CounterLiveView.mount(%{}, %{}, socket)

      assert Map.has_key?(socket.assigns, :_filament_tree)
      assert is_map(socket.assigns._filament_tree)
      assert socket.assigns._filament_tree["root"]

      assert Map.has_key?(socket.assigns, :_filament_rendered)
      assert %Phoenix.LiveView.Rendered{} = socket.assigns._filament_rendered

      assert Map.has_key?(socket.assigns, :_filament_pending_effects)
      assert socket.assigns._filament_pending_effects == []
    end

    test "passes props from socket.assigns to component" do
      socket = test_socket(%{count: 42})

      {:ok, socket} = CounterLiveView.mount(%{}, %{}, socket)

      assert socket.assigns._filament_tree["root"].props == %{count: 42}
    end
  end

  describe "handle_event/3" do
    test "handles filament: prefixed events" do
      socket = %Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{},
          _filament_rendered: {:safe, []},
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
      }

      assert {:noreply, _socket} = CounterLiveView.handle_event("filament:test", %{}, socket)
    end

    test "forwards regular events to root component when handle_event/3 is defined" do
      socket = %Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{"root" => %{component: CounterComponent, props: %{count: 0}}},
          _filament_rendered: {:safe, []},
          _filament_pending_effects: [],
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
      }

      # Counter component doesn't define handle_event, so this should be a noop
      assert {:noreply, _new_socket} = CounterLiveView.handle_event("click", %{}, socket)
    end
  end

  # --- static_subscribe option ---

  defmodule ObservableComponent do
    @moduledoc false
    use Filament.Component
    use Filament.Observable.GenServer

    def start_link(initial), do: GenServer.start_link(__MODULE__, initial)
    def init(n), do: {:ok, n}

    defcomponent do
      prop(:server, :any, required: true)

      @impl true
      def render(%{server: server}) do
        value =
          use_observable(server, fn
            :disconnected -> :disconnected
            n -> n
          end)

        ~F"""
        <div>{value}</div>
        """
      end
    end
  end

  defmodule StaticSubscribeLiveView do
    use Filament.LiveView, static_subscribe: true

    def root_component, do: ObservableComponent
  end

  defmodule NoStaticSubscribeLiveView do
    use Filament.LiveView, static_subscribe: false

    def root_component, do: ObservableComponent
  end

  describe "static_subscribe option" do
    test "default (true): disconnected socket returns real data" do
      {:ok, server} = ObservableComponent.start_link(42)
      socket = test_socket(%{server: server})

      {:ok, socket} = StaticSubscribeLiveView.mount(%{}, %{}, socket)

      rendered = socket.assigns._filament_rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert rendered =~ "42"
      refute rendered =~ "disconnected"
    end

    test "static_subscribe: false — disconnected socket returns :disconnected value" do
      {:ok, server} = ObservableComponent.start_link(42)
      socket = test_socket(%{server: server})

      {:ok, socket} = NoStaticSubscribeLiveView.mount(%{}, %{}, socket)

      rendered = socket.assigns._filament_rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert rendered =~ "disconnected"
      refute rendered =~ "42"
    end
  end

  describe "handle_info/2" do
    test "handles filament_observable_updates messages" do
      socket = %Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{},
          _filament_rendered: {:safe, []},
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
      }

      assert {:noreply, _socket} =
               CounterLiveView.handle_info({:filament_observable_updates, [{"root", 0, 42}]}, socket)
    end

    test "handles cell_update messages with no matching fiber" do
      socket = %Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{},
          _filament_rendered: {:safe, []},
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
      }

      assert {:noreply, _socket} =
               CounterLiveView.handle_info(
                 {:cell_update, {self(), "missing", 0}, 7},
                 socket
               )
    end

    test "handles cell_update messages with malformed subscriber tuple" do
      socket = %Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{},
          _filament_rendered: {:safe, []},
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
      }

      assert {:noreply, ^socket} =
               CounterLiveView.handle_info({:cell_update, :not_a_tuple, 7}, socket)
    end
  end

  describe "handle_info/2 :cell_update end-to-end" do
    defmodule CellCounter do
      @moduledoc false
      use Filament.Observable.GenServer

      def start_link(initial \\ 0), do: GenServer.start_link(__MODULE__, initial, [])
      def bump(server), do: GenServer.call(server, :bump)

      @impl GenServer
      def init(n), do: {:ok, n}

      @impl GenServer
      def handle_call(:bump, _from, n) do
        new = n + 1
        notify_observers(new)
        {:reply, new, new}
      end
    end

    defmodule CellViewComponent do
      @moduledoc false
      use Filament.Component

      defcomponent do
        prop(:cell, :any, required: true)

        def render(%{cell: cell}) do
          count = use_cell(cell, & &1)
          ~F"<p>cell-count: {count}</p>"
        end
      end
    end

    defmodule CellLiveView do
      use Filament.LiveView

      def root_component, do: CellViewComponent
    end

    test "cell_update message updates the slot and re-renders" do
      {:ok, server} = CellCounter.start_link(0)
      cell = {Filament.Observable.GenServer, server}

      socket = test_socket(%{cell: cell})
      {:ok, socket} = CellLiveView.mount(%{}, %{}, socket)

      html_before =
        socket.assigns._filament_rendered |> Safe.to_iodata() |> IO.iodata_to_binary()

      assert html_before =~ "cell-count: 0"

      # Bumping the server fires notify_cell_each, which sends `:cell_update`
      # to the subscriber pid (this test process). We capture the message and
      # then feed it back through the LiveView's handle_info to prove the
      # whole loop re-renders.
      CellCounter.bump(server)
      assert_receive {:cell_update, subscriber, 1}, 200

      {:noreply, socket} = CellLiveView.handle_info({:cell_update, subscriber, 1}, socket)

      html_after =
        socket.assigns._filament_rendered |> Safe.to_iodata() |> IO.iodata_to_binary()

      assert html_after =~ "cell-count: 1"
    end
  end

  describe "handle_info/2 :cell_resubscribe" do
    alias Filament.LiveViewTest.CellCounter
    alias Filament.LiveViewTest.CellLiveView

    test "marks the slot :needs_resubscribe and re-renders" do
      {:ok, server} = CellCounter.start_link(0)
      cell = {Filament.Observable.GenServer, server}

      socket = test_socket(%{cell: cell})
      {:ok, socket} = CellLiveView.mount(%{}, %{}, socket)

      # Find the subscriber tuple (one slot exists on root after mount).
      [{slot_index, _}] =
        socket.assigns._filament_tree["root"].hook_slots |> Enum.to_list()

      subscriber = {self(), "root", slot_index}

      {:noreply, socket} =
        CellLiveView.handle_info({:cell_resubscribe, subscriber}, socket)

      # After resubscribe, the slot should hold a fresh :cell_subscribed value
      # (set by the re-render which calls cell_subscribe_fresh).
      assert {:cell_subscribed, _} =
               Map.fetch!(socket.assigns._filament_tree["root"].hook_slots, slot_index)
    end

    test "no matching fiber returns unchanged socket" do
      socket = %Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{},
          _filament_rendered: {:safe, []},
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
      }

      assert {:noreply, _socket} =
               CellLiveView.handle_info(
                 {:cell_resubscribe, {self(), "missing", 0}},
                 socket
               )
    end

    test "malformed subscriber tuple returns unchanged socket" do
      socket = %Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{},
          _filament_rendered: {:safe, []},
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
      }

      assert {:noreply, ^socket} =
               CellLiveView.handle_info({:cell_resubscribe, :not_a_tuple}, socket)
    end

    test "saturated mailbox triggers cell_resubscribe end-to-end" do
      {:ok, server} = CellCounter.start_link(0)
      cell = {Filament.Observable.GenServer, server}

      # Use a sleeping decoy pid as the subscriber so we can flood its mailbox.
      decoy = spawn(fn -> Process.sleep(:infinity) end)

      subscriber = {decoy, "root", 0}
      {:ok, _} = Filament.Cell.subscribe(cell, subscriber, &Function.identity/1)

      # Flood past @max_mailbox_depth (default 100).
      for _ <- 1..110, do: send(decoy, :__flood__)

      ExUnit.CaptureLog.capture_log(fn ->
        CellCounter.bump(server)
        Logger.flush()
      end)

      {:messages, msgs} = Process.info(decoy, :messages)
      assert Enum.any?(msgs, &match?({:cell_resubscribe, ^subscriber}, &1))

      Process.exit(decoy, :kill)
    end
  end

  describe "cell server restart" do
    alias Filament.LiveViewTest.CellCounter
    alias Filament.LiveViewTest.CellLiveView

    test "after server death, resubscribe yields :disconnected; restart resumes updates" do
      Process.flag(:trap_exit, true)
      {:ok, server} = CellCounter.start_link(0)
      cell = {Filament.Observable.GenServer, server}

      socket = test_socket(%{cell: cell})
      {:ok, socket} = CellLiveView.mount(%{}, %{}, socket)

      [{slot_index, _}] =
        socket.assigns._filament_tree["root"].hook_slots |> Enum.to_list()

      # Kill the server. The cell is now unreachable.
      ref = Process.monitor(server)
      Process.exit(server, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}, 200

      subscriber = {self(), "root", slot_index}

      # Manually deliver the resubscribe (the dead transport can't send it).
      {:noreply, socket} =
        CellLiveView.handle_info({:cell_resubscribe, subscriber}, socket)

      html_disconnected =
        socket.assigns._filament_rendered |> Safe.to_iodata() |> IO.iodata_to_binary()

      # The cell can't reach its (dead) source, so use_cell yields :disconnected.
      assert html_disconnected =~ "cell-count: disconnected"

      # Restart the cell against a fresh server. Component re-render via a
      # subsequent resubscribe should pick it up.
      {:ok, server2} = CellCounter.start_link(7)
      cell2 = {Filament.Observable.GenServer, server2}

      socket =
        socket
        |> Phoenix.Component.assign(:cell, cell2)
        |> then(fn s ->
          tree = s.assigns._filament_tree
          new_slots = Map.put(tree["root"].hook_slots, slot_index, :needs_resubscribe)
          new_tree = Map.put(tree, "root", %{tree["root"] | hook_slots: new_slots})

          {final_tree, rendered, _} =
            Filament.Reconciler.update(new_tree, "root", %{cell: cell2}, owner_pid: self())

          s
          |> Phoenix.Component.assign(:_filament_tree, final_tree)
          |> Phoenix.Component.assign(
            :_filament_rendered,
            Filament.Web.to_rendered(rendered)
          )
        end)

      html_after =
        socket.assigns._filament_rendered |> Safe.to_iodata() |> IO.iodata_to_binary()

      assert html_after =~ "cell-count: 7"

      # And subsequent bumps are delivered.
      CellCounter.bump(server2)
      assert_receive {:cell_update, _sub, 8}, 200
    end
  end
end
