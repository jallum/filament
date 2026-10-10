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
      prop(:cell, :any, required: true)

      def render(%{cell: cell}) do
        {field, set_field} = use_state(:a)
        value = use_value(cell, &Map.fetch!(&1, field))
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
      prop(:cell, :any, required: true)

      def render(%{cell: cell}) do
        a = use_value(cell, & &1.a)
        b = use_value(cell, & &1.b)
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

  defp socket(raw) do
    server = start_supervised!({Store, raw})
    cell = Filament.Source.new(Filament.Observable.GenServer, server)

    %Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}, cell: cell},
      private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
    }
  end

  defp subscriber(tree, slot_index) do
    {:cell_subscribed, _cell, _raw, subscriber, _projection, _value} = tree["root"].hook_slots[slot_index]
    subscriber
  end

  test "unchanged projection skips rendering but retains raw state for a fresh local closure" do
    {:ok, socket} = Host.mount(%{}, %{}, socket(%{a: 1, b: 10}))
    assert_receive {:rendered, 1}
    sub = subscriber(socket.assigns._filament_tree, 1)

    {:noreply, socket} = Host.handle_info({:cell_update, sub, %{a: 1, b: 11}}, socket)
    refute_receive {:rendered, _}

    {:noreply, socket} =
      Host.handle_info(Filament.StateHelper.set_state(socket.assigns._filament_tree, "root", 0, :b), socket)

    assert_receive {:rendered, 11}

    {:noreply, socket} = Host.handle_info({:cell_update, sub, %{a: 2, b: 11}}, socket)
    refute_receive {:rendered, _}
    {:noreply, _socket} = Host.handle_info({:cell_update, sub, %{a: 2, b: 12}}, socket)
    assert_receive {:rendered, 12}
  end

  test "projected equality is strict and nil is a real value" do
    {:ok, socket} = Host.mount(%{}, %{}, socket(%{a: 1, b: 0}))
    assert_receive {:rendered, 1}
    sub = subscriber(socket.assigns._filament_tree, 1)

    {:noreply, socket} = Host.handle_info({:cell_update, sub, %{a: 1.0, b: 0}}, socket)
    assert_receive {:rendered, value}
    assert value === 1.0
    {:noreply, socket} = Host.handle_info({:cell_update, sub, %{a: nil, b: 0}}, socket)
    assert_receive {:rendered, nil}
    {:noreply, _socket} = Host.handle_info({:cell_update, sub, %{a: nil, b: 1}}, socket)
    refute_receive {:rendered, _}
  end

  test "a mixed batch renders once if any projection changes and ignores removed slots" do
    {:ok, socket} = BothHost.mount(%{}, %{}, socket(%{a: 1, b: 10}))
    assert_receive {:both_rendered, 1, 10}
    tree = socket.assigns._filament_tree
    {owner, _fiber, _slot, token} = sub_a = subscriber(tree, 0)
    sub_b = subscriber(tree, 1)

    updates = [
      {sub_a, %{a: 1, b: 11}},
      {sub_b, %{a: 1, b: 11}},
      {{owner, "removed", 0, token}, nil},
      {{owner, "root", 99, token}, nil}
    ]

    {:noreply, socket} = BothHost.handle_info({:cell_updates, updates}, socket)
    assert_receive {:both_rendered, 1, 11}
    refute_receive {:both_rendered, _, _}
    refute Map.has_key?(socket.assigns._filament_tree["root"].hook_slots, 99)
    {:noreply, _socket} = BothHost.handle_info({:cell_updates, updates}, socket)
    refute_receive {:both_rendered, _, _}
  end

  test "LiveComponent also retains unchanged raw updates without rendering" do
    %Socket{assigns: %{cell: cell}} = base = socket(%{a: 1, b: 10})
    {:ok, socket} = Filament.LiveComponent.mount(%{base | assigns: %{__changed__: %{}}})
    {:ok, socket} = Filament.LiveComponent.update(%{component: Selected, id: "selected", cell: cell}, socket)
    assert_receive {:rendered, 1}
    sub = subscriber(socket.assigns._filament_tree, 1)

    {:ok, socket} = Filament.LiveComponent.update(%{filament_msg: {:cell_update, sub, %{a: 1, b: 11}}}, socket)
    refute_receive {:rendered, _}

    {:ok, _socket} =
      Filament.LiveComponent.update(
        %{filament_msg: Filament.StateHelper.set_state(socket.assigns._filament_tree, "root", 0, :b)},
        socket
      )

    assert_receive {:rendered, 11}
  end
end
