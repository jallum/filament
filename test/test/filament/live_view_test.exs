defmodule Filament.LiveViewTest do
  use ExUnit.Case, async: false
  use Phoenix.ConnTest

  import Phoenix.LiveViewTest
  
  @endpoint __MODULE__

  # Define test modules inline
  defmodule CounterComponent do
    use Filament.Component

    defcomponent Counter do
      prop :count, :integer, required: true

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

    def root_component(), do: CounterComponent.Counter

    def mount(_params, _session, socket) do
      {:ok, assign(socket, count: 0)}
    end
  end

  setup do
    conn = Phoenix.ConnTest.build_conn()
    {:ok, conn: conn}
  end

  describe "mount/3" do
    test "mounts successfully and returns {:ok, view, html}", %{conn: conn} do
      {:ok, view, html} = live_isolated(conn, CounterLiveView, session: %{"count" => 0})

      assert %Phoenix.LiveViewTest.View{} = view
      assert is_binary(html)
    end

    test "html contains the rendered output of CounterComponent", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, CounterLiveView, session: %{"count" => 0})

      assert html =~ "Counter: 0"
    end

    test "socket has _filament_tree assign", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, CounterLiveView, session: %{"count" => 0})

      assert Map.has_key?(view.assigns, :_filament_tree)
      assert is_map(view.assigns._filament_tree)
      assert view.assigns._filament_tree["root"]
    end

    test "socket has _filament_rendered assign", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, CounterLiveView, session: %{"count" => 0})

      assert Map.has_key?(view.assigns, :_filament_rendered)
      assert %Phoenix.LiveView.Rendered{} = view.assigns._filament_rendered
    end
  end

  describe "render/1" do
    test "returns the pre-rendered Filament output", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, CounterLiveView, session: %{"count" => 0})

      rendered = CounterLiveView.render(view.assigns)
      assert rendered == view.assigns._filament_rendered
      assert %Phoenix.LiveView.Rendered{} = rendered
    end

    test "rendered html contains no filament debug artifacts", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, CounterLiveView, session: %{"count" => 0})

      refute html =~ ~r/filament:/
      refute html =~ ~r/_filament/
    end
  end

  describe "handle_event/3" do
    test "forwards regular events to root component when handle_event/3 is defined", %{conn: conn} do
      {:ok, view, _html} = live_isolated(conn, CounterLiveView, session: %{"count" => 0})

      # Counter component doesn't define handle_event, so this should be a noop
      assert {:noreply, _socket} = render_click(view, :inc)
    end
  end

  describe "root_component/0 callback" do
    test "is implemented in the LiveView" do
      assert function_exported?(CounterLiveView, :root_component, 0)
      assert CounterLiveView.root_component() == CounterComponent.Counter
    end
  end
end
