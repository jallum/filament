defmodule Filament.SubscriptionGenerationTest do
  use ExUnit.Case, async: true

  alias Filament.LiveView
  alias Filament.Reconciler
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket

  defmodule Store do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link(initial), do: GenServer.start_link(__MODULE__, initial)
    def init(value), do: {:ok, value}

    def handle_call({:set, value}, _from, _) do
      notify_observers(value)
      {:reply, :ok, value}
    end

    def handle_call(:subscribers, _from, value) do
      {:reply, Map.keys(Process.get(:__filament_cell_subscribers__, %{})), value}
    end
  end

  defmodule Value do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:source, :any, required: true)

      def render(%{source: source}) do
        value = use_value(source, &Function.identity/1)
        ~F"<p>{value}</p>"
      end
    end
  end

  defmodule CustomTransport do
    @moduledoc false
    @behaviour Filament.Cell

    def subscribe(observer, subscriber, projection) do
      send(observer, {:subscribed, subscriber})
      {:ok, projection.(5)}
    end

    def unsubscribe(observer, subscriber) do
      send(observer, {:unsubscribed, subscriber})
      :ok
    end

    def current(_, projection), do: projection.(5)
  end

  defp subscriber(tree) do
    {:cell_subscribed, _, _, subscriber, _, _} = tree["root"].hook_slots[0]
    subscriber
  end

  defp html(walked), do: walked |> Filament.Web.to_rendered() |> Safe.to_iodata() |> IO.iodata_to_binary()

  setup do
    a = start_supervised!({Store, 10}, id: :a)
    b = start_supervised!({Store, 20}, id: :b)
    %{a: a, b: b, source_a: Store.cell(a), source_b: Store.cell(b)}
  end

  test "queued old updates and resubscribe requests cannot overwrite a replacement", ctx do
    {tree, _, _} = Reconciler.mount(Value, %{source: ctx.source_a}, owner_pid: self())
    old = subscriber(tree)
    GenServer.call(ctx.a, {:set, 11})
    {tree, walked, _} = Reconciler.update(tree, "root", %{source: ctx.source_b}, owner_pid: self())
    current = subscriber(tree)
    assert html(walked) == "<p>20</p>"
    assert GenServer.call(ctx.a, :subscribers) == []
    assert GenServer.call(ctx.b, :subscribers) == [current]
    assert_receive {:cell_update, ^old, 11}
    assert {:ok, ^tree} = LiveView.apply_message(tree, {:cell_update, old, 11})
    assert {:ok, ^tree} = LiveView.apply_message(tree, {:cell_resubscribe, old})
    assert {:ok, ^tree} = LiveView.apply_message(tree, {:cell_update, {self(), "root", 0}, 99})
    assert {:ok, ^tree} = LiveView.apply_message(tree, {:cell_resubscribe, {self(), "root", 0}})

    {stable, _, _} = Reconciler.update(tree, "root", %{source: ctx.source_b}, owner_pid: self())
    assert subscriber(stable) == current
    GenServer.call(ctx.b, {:set, 21})
    assert_receive {:cell_update, ^current, 21}
    {:rerender, tree} = LiveView.apply_message(stable, {:cell_updates, [{old, 11}, {current, 21}, {old, 12}]})
    {tree, walked, _} = Reconciler.update(tree, "root", %{source: ctx.source_b}, owner_pid: self())
    assert html(walked) == "<p>21</p>"
    Reconciler.unmount(tree, owner_pid: self())
    assert GenServer.call(ctx.b, :subscribers) == []
  end

  test "refresh keeps the identity; remount changes the generation and cleans up the exact old identity", ctx do
    props = %{source: ctx.source_a}
    {tree, _, _} = Reconciler.mount(Value, props, owner_pid: self())
    old = subscriber(tree)
    {:rerender, tree} = LiveView.apply_message(tree, {:cell_resubscribe, old})
    assert {:ok, ^tree} = LiveView.apply_message(tree, {:cell_update, old, 100})
    {tree, _, _} = Reconciler.update(tree, "root", props, owner_pid: self())
    refreshed = subscriber(tree)
    assert refreshed == old
    assert GenServer.call(ctx.a, :subscribers) == [refreshed]
    Reconciler.unmount(tree, owner_pid: self())
    {tree, _, _} = Reconciler.mount(Value, props, owner_pid: self())
    remounted = subscriber(tree)
    refute remounted == refreshed
    assert {:ok, ^tree} = LiveView.apply_message(tree, {:cell_update, refreshed, 100})
    assert GenServer.call(ctx.a, :subscribers) == [remounted]
    {:rerender, tree} = LiveView.apply_message(tree, {:cell_resubscribe, remounted})
    Reconciler.unmount(tree, owner_pid: self())
    assert GenServer.call(ctx.a, :subscribers) == []
  end

  test "test harness ignores stale updates and refreshes after a source swap", ctx do
    view = Filament.Test.mount!(Value, %{source: ctx.source_a})
    old = subscriber(view.fiber_tree)
    view = Filament.Test.update(%{view | props: %{source: ctx.source_b}})
    current = subscriber(view.fiber_tree)
    send(self(), {:cell_updates, [{old, 999}]})
    send(self(), {:cell_resubscribe, old})
    view = Filament.Test.update(view)
    assert Filament.Test.render_text(view) == "20"
    assert subscriber(view.fiber_tree) == current
    GenServer.call(ctx.b, {:set, 22})
    assert view |> Filament.Test.update() |> Filament.Test.render_text() == "22"
  end

  test "LiveComponent ignores old generations without rerendering", ctx do
    socket = %Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}},
      private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
    }

    {:ok, socket} = Filament.LiveComponent.mount(socket)
    {:ok, socket} = Filament.LiveComponent.update(%{component: Value, source: ctx.source_a}, socket)
    old = subscriber(socket.assigns._filament_tree)
    {:ok, socket} = Filament.LiveComponent.update(%{component: Value, source: ctx.source_b}, socket)
    assert {:ok, ^socket} = Filament.LiveComponent.update(%{filament_msg: {:cell_update, old, 999}}, socket)
    assert {:ok, ^socket} = Filament.LiveComponent.update(%{filament_msg: {:cell_resubscribe, old}}, socket)
    assert {:ok, ^socket} = Filament.LiveComponent.update(%{filament_msg: {:cell_updates, [{old, 999}]}}, socket)
  end

  test "custom transports receive and cancel an opaque generation-scoped identity" do
    source = Filament.Source.new(CustomTransport, self())
    {tree, _, _} = Reconciler.mount(Value, %{source: source}, owner_pid: self())
    identity = subscriber(tree)
    assert_receive {:subscribed, ^identity}
    {:rerender, tree} = LiveView.apply_message(tree, {:cell_update, identity, 7})
    {tree, walked, _} = Reconciler.update(tree, "root", %{source: source}, owner_pid: self())
    assert html(walked) == "<p>7</p>"
    refute_receive {:subscribed, _}
    Reconciler.unmount(tree, owner_pid: self())
    assert_receive {:unsubscribed, ^identity}
    refute_receive {:unsubscribed, _}
  end
end
