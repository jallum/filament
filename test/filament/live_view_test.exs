defmodule Filament.LiveViewTest do
  use ExUnit.Case, async: false

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
      assert CounterLiveView.root_component() == CounterComponent.Counter
    end
  end

  describe "render/1" do
    test "returns valid Phoenix.LiveView.Rendered struct" do
      # Simulate mount
      socket = %Phoenix.LiveView.Socket{
        assigns: %{count: 5, __changed__: %{}}
      }
      {:ok, socket} = CounterLiveView.mount(%{}, %{}, socket)
      
      rendered = CounterLiveView.render(socket.assigns)
      assert %Phoenix.LiveView.Rendered{} = rendered
      
      # Convert to HTML and verify
      html = Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()
      assert html =~ "Counter: 5"
    end

    test "rendered html contains no filament debug artifacts" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{count: 0, __changed__: %{}}
      }
      {:ok, socket} = CounterLiveView.mount(%{}, %{}, socket)
      
      rendered = CounterLiveView.render(socket.assigns)
      html = Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()
      
      refute html =~ ~r/filament:/
      refute html =~ ~r/_filament/
    end
  end

  describe "mount/3" do
    test "assigns _filament_tree and _filament_rendered" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{count: 0, __changed__: %{}}
      }
      
      {:ok, socket} = CounterLiveView.mount(%{}, %{}, socket)
      
      assert Map.has_key?(socket.assigns, :_filament_tree)
      assert is_map(socket.assigns._filament_tree)
      assert socket.assigns._filament_tree["root"]
      
      assert Map.has_key?(socket.assigns, :_filament_rendered)
      assert %Phoenix.LiveView.Rendered{} = socket.assigns._filament_rendered
    end

    test "passes props from socket.assigns to component" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{count: 42, __changed__: %{}}
      }
      
      {:ok, socket} = CounterLiveView.mount(%{}, %{}, socket)
      
      assert socket.assigns._filament_tree["root"].props == %{count: 42}
    end
  end

  describe "handle_event/3" do
    test "handles filament: prefixed events" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{count: 0, _filament_tree: %{}, _filament_rendered: %Phoenix.LiveView.Rendered{}, __changed__: %{}}
      }
      
      assert {:noreply, _socket} = CounterLiveView.handle_event("filament:test", %{}, socket)
    end

    test "forwards regular events to root component when handle_event/3 is defined" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{count: 0, _filament_tree: %{"root" => %{component: CounterComponent.Counter, props: %{count: 0}}}, _filament_rendered: %Phoenix.LiveView.Rendered{}, __changed__: %{}}
      }
      
      # Counter component doesn't define handle_event, so this should be a noop
      assert {:noreply, socket} = CounterLiveView.handle_event("click", %{}, socket)
    end
  end

  describe "handle_info/2" do
    test "handles filament_update messages" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{count: 0, _filament_tree: %{}, _filament_rendered: %Phoenix.LiveView.Rendered{}, __changed__: %{}}
      }
      
      assert {:noreply, _socket} = CounterLiveView.handle_info({:filament_update, "root", %{count: 5}}, socket)
    end
  end
end
