defmodule Filament.LiveViewTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket

  # Helper: create a socket with proper lifecycle structures for attach_hook
  defp test_socket(assigns) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      private: %{
        live_temp: %{},
        lifecycle: Phoenix.LiveView.Lifecycle.__struct__()
      }
    }
  end

  # Define test modules inline
  defmodule CounterComponent do
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

    def root_component(), do: CounterComponent
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
      assert %Phoenix.LiveView.Rendered{} = rendered

      # Convert to HTML and verify
      html = Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()
      assert html =~ "Counter: 5"
    end

    test "rendered html contains no filament debug artifacts" do
      socket = test_socket(%{count: 0})

      {:ok, socket} = CounterLiveView.mount(%{}, %{}, socket)

      rendered = CounterLiveView.render(socket.assigns)
      html = Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()

      refute html =~ ~r/filament:/
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
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{},
          _filament_rendered: %Phoenix.LiveView.Rendered{},
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Phoenix.LiveView.Lifecycle.__struct__()}
      }

      assert {:noreply, _socket} = CounterLiveView.handle_event("filament:test", %{}, socket)
    end

    test "forwards regular events to root component when handle_event/3 is defined" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{"root" => %{component: CounterComponent, props: %{count: 0}}},
          _filament_rendered: %Phoenix.LiveView.Rendered{},
          _filament_pending_effects: [],
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Phoenix.LiveView.Lifecycle.__struct__()}
      }

      # Counter component doesn't define handle_event, so this should be a noop
      assert {:noreply, _new_socket} = CounterLiveView.handle_event("click", %{}, socket)
    end
  end

  describe "handle_info/2" do
    test "handles filament_observable_update messages" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          count: 0,
          _filament_tree: %{},
          _filament_rendered: %Phoenix.LiveView.Rendered{},
          __changed__: %{}
        },
        private: %{live_temp: %{}, lifecycle: Phoenix.LiveView.Lifecycle.__struct__()}
      }

      assert {:noreply, _socket} =
               CounterLiveView.handle_info({:filament_observable_update, "root", 0, 42}, socket)
    end
  end
end
