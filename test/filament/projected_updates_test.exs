defmodule Filament.ProjectedUpdatesTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket

  defmodule Store do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link(raw), do: GenServer.start_link(__MODULE__, raw)
    def init(raw), do: {:ok, raw}
  end

  defmodule Selected do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(%{server: server}) do
        {field, set_field} = use_state(:a)
        value = use_observable(server, &Map.fetch!(&1, field))
        send(self(), {:rendered, value})
        ~F"<p>{inspect(value)}</p><button on_click={fn -> set_field.(:b) end}>b</button>"
      end
    end
  end

  defmodule Host do
    @moduledoc false
    use Filament.LiveView

    def root_component, do: Selected
  end

  defmodule Both do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(%{server: server}) do
        a = use_observable(server, & &1.a)
        b = use_observable(server, & &1.b)
        send(self(), {:both_rendered, a, b})
        ~F"<p>{inspect({a, b})}</p>"
      end
    end
  end

  defmodule BothHost do
    @moduledoc false
    use Filament.LiveView

    def root_component, do: Both
  end

  defp socket do
    %Socket{assigns: %{__changed__: %{}}, private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}}
  end

  test "unchanged projection skips rendering but retains raw state for a fresh local closure" do
    server = start_supervised!({Store, %{a: 1, b: 10}})
    {:ok, socket} = Host.mount(%{}, %{}, Phoenix.Component.assign(socket(), :server, server))
    assert_receive {:rendered, 1}

    {:noreply, socket} = Host.handle_info({:filament_observable_updates, [{"root", 1, %{a: 1, b: 11}}]}, socket)
    refute_receive {:rendered, _}

    {:noreply, socket} = Host.handle_info({:filament_set_state, "root", 0, :b}, socket)
    assert_receive {:rendered, 11}

    {:noreply, socket} = Host.handle_info({:filament_observable_updates, [{"root", 1, %{a: 2, b: 11}}]}, socket)
    refute_receive {:rendered, _}
    {:noreply, _socket} = Host.handle_info({:filament_observable_updates, [{"root", 1, %{a: 2, b: 12}}]}, socket)
    assert_receive {:rendered, 12}
  end

  test "projected equality is strict and nil is a real value" do
    server = start_supervised!({Store, %{a: 1, b: 0}})
    {:ok, socket} = Host.mount(%{}, %{}, Phoenix.Component.assign(socket(), :server, server))
    assert_receive {:rendered, 1}

    {:noreply, socket} = Host.handle_info({:filament_observable_updates, [{"root", 1, %{a: 1.0, b: 0}}]}, socket)
    assert_receive {:rendered, value}
    assert value === 1.0
    {:noreply, socket} = Host.handle_info({:filament_observable_updates, [{"root", 1, %{a: nil, b: 0}}]}, socket)
    assert_receive {:rendered, nil}
    {:noreply, _socket} = Host.handle_info({:filament_observable_updates, [{"root", 1, %{a: nil, b: 1}}]}, socket)
    refute_receive {:rendered, _}
  end

  test "a mixed batch renders once if any projection changes and ignores removed slots" do
    server = start_supervised!({Store, %{a: 1, b: 10}})
    {:ok, socket} = BothHost.mount(%{}, %{}, Phoenix.Component.assign(socket(), :server, server))
    assert_receive {:both_rendered, 1, 10}
    updates = [{"root", 0, %{a: 1, b: 11}}, {"root", 1, %{a: 1, b: 11}}, {"removed", 0, nil}, {"root", 99, nil}]
    {:noreply, socket} = BothHost.handle_info({:filament_observable_updates, updates}, socket)
    assert_receive {:both_rendered, 1, 11}
    refute_receive {:both_rendered, _, _}
    refute Map.has_key?(socket.assigns._filament_tree["root"].hook_slots, 99)
    {:noreply, _socket} = BothHost.handle_info({:filament_observable_updates, updates}, socket)
    refute_receive {:both_rendered, _, _}
  end

  test "LiveComponent also retains unchanged raw updates without rendering" do
    server = start_supervised!({Store, %{a: 1, b: 10}})
    {:ok, socket} = Filament.LiveComponent.mount(socket())
    {:ok, socket} = Filament.LiveComponent.update(%{component: Selected, id: "selected", server: server}, socket)
    assert_receive {:rendered, 1}

    {:ok, socket} =
      Filament.LiveComponent.update(
        %{filament_msg: {:filament_observable_updates, [{"root", 1, %{a: 1, b: 11}}]}},
        socket
      )

    refute_receive {:rendered, _}
    {:ok, _socket} = Filament.LiveComponent.update(%{filament_msg: {:filament_set_state, "root", 0, :b}}, socket)
    assert_receive {:rendered, 11}
  end
end
