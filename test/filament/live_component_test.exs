defmodule Filament.LiveComponentTest do
  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket

  defp test_socket(assigns \\ %{}) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      private: %{
        live_temp: %{},
        lifecycle: Lifecycle.__struct__()
      }
    }
  end

  defmodule LabelComp do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:label, :string, default: "hello")

      def render(%{label: label}) do
        ~F"""
        <span id="lbl">{label}</span>
        """
      end
    end
  end

  defmodule CounterComp do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:initial, :integer, default: 0)

      def render(%{initial: initial}) do
        {count, set_count} = use_state(initial)

        ~F"""
        <div>
          <span id="count">{count}</span>
          <button on_click={fn -> set_count.(count + 1) end}>+</button>
        </div>
        """
      end
    end
  end

  describe "module structure" do
    test "is a Phoenix LiveComponent" do
      assert Filament.LiveComponent.__live__() == %{kind: :component, layout: false}
    end

    test "exports expected callbacks" do
      Code.ensure_loaded!(Filament.LiveComponent)
      fns = Map.new(Filament.LiveComponent.__info__(:functions))
      assert Map.has_key?(fns, :mount)
      assert Map.has_key?(fns, :update)
      assert Map.has_key?(fns, :handle_event)
      assert Map.has_key?(fns, :render)
    end
  end

  describe "mount/1" do
    test "initialises fiber_tree to nil" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())
      assert socket.assigns._filament_tree == nil
    end

    test "initialises pending_effects to empty list" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())
      assert socket.assigns._filament_pending_effects == []
    end
  end

  describe "update/2 — first mount" do
    test "mounts component and sets rendered" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())

      assigns = %{id: "test", component: LabelComp, label: "World"}
      {:ok, socket} = Filament.LiveComponent.update(assigns, socket)

      assert socket.assigns._filament_tree
      rendered = socket.assigns._filament_rendered
      assert %Phoenix.LiveView.Rendered{} = rendered

      html = rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "World"
    end

    test "props are passed to the component" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())
      assigns = %{id: "t", component: LabelComp, label: "Custom"}
      {:ok, socket} = Filament.LiveComponent.update(assigns, socket)

      html =
        socket.assigns._filament_rendered
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "Custom"
    end
  end

  describe "update/2 — re-render with new props" do
    test "reconciles with updated props" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())
      assigns1 = %{id: "t", component: LabelComp, label: "First"}
      {:ok, socket} = Filament.LiveComponent.update(assigns1, socket)

      assigns2 = %{id: "t", component: LabelComp, label: "Second"}
      {:ok, socket} = Filament.LiveComponent.update(assigns2, socket)

      html =
        socket.assigns._filament_rendered
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "Second"
      refute html =~ "First"
    end
  end

  describe "update/2 — filament_msg forwarding" do
    test "ignores filament_msg for unknown fiber" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())
      assigns = %{id: "t", component: LabelComp, label: "X"}
      {:ok, socket} = Filament.LiveComponent.update(assigns, socket)

      msg = {:filament_set_state, "nonexistent_fiber", 0, 42}
      {:ok, socket2} = Filament.LiveComponent.update(%{filament_msg: msg}, socket)

      # Socket unchanged
      assert socket2.assigns._filament_tree == socket.assigns._filament_tree
    end

    test "ignores unknown message types" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())
      assigns = %{id: "t", component: LabelComp, label: "X"}
      {:ok, socket} = Filament.LiveComponent.update(assigns, socket)

      msg = {:some_unknown_msg, "data"}
      {:ok, socket2} = Filament.LiveComponent.update(%{filament_msg: msg}, socket)

      assert socket2.assigns._filament_tree == socket.assigns._filament_tree
    end
  end

  describe "handle_event/3" do
    test "returns noreply for unknown event ref" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())
      assigns = %{id: "t", component: LabelComp, label: "X"}
      {:ok, socket} = Filament.LiveComponent.update(assigns, socket)

      # Stale ref — fiber that no longer exists
      {:noreply, ^socket} =
        Filament.LiveComponent.handle_event("filament:ghost_fiber:0", %{}, socket)
    end

    test "returns noreply for non-filament events" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())
      assigns = %{id: "t", component: LabelComp}
      {:ok, socket} = Filament.LiveComponent.update(assigns, socket)

      # handle_event only handles "filament:..." events; others fall through.
      # Verify no crash for a malformed filament ref.
      {:noreply, ^socket} =
        Filament.LiveComponent.handle_event("filament:no_colon", %{}, socket)
    end
  end

  defmodule Store do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, 0)
    def init(value), do: {:ok, value}

    def handle_call({:set, value}, _from, _) do
      notify_observers(value)
      {:reply, :ok, value}
    end
  end

  defmodule ValueChild do
    @moduledoc false
    use Filament.Component

    def render(%{source: source}) do
      value = use_value(source, &Function.identity/1)
      {local, _} = use_state(0)
      {:element, "span", [], ["#{value}/#{local}"]}
    end
  end

  defmodule ValueRoot do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:source, :any, required: true)
      prop(:observer, :any, required: true)

      def render(%{observer: observer} = props) do
        send(observer, :root_rendered)

        {:element, "section", [],
         [
           {:text, "wrapper"},
           {:component, ValueChild, props, "a"},
           {:component, ValueChild, props, "b"}
         ]}
      end
    end
  end

  test "batched Cell and child state updates preserve the full embedded tree" do
    server = start_supervised!(Store)
    {:ok, socket} = Filament.LiveComponent.mount(test_socket())

    {:ok, socket} =
      Filament.LiveComponent.update(
        %{component: ValueRoot, source: Store.cell(server), observer: self()},
        socket
      )

    assert_receive :root_rendered
    GenServer.call(server, {:set, 10})
    assert_receive {:cell_updates, updates}
    updates = updates ++ [{{self(), "missing", 0}, 99}]
    {:ok, socket} = Filament.LiveComponent.update(%{filament_msg: {:cell_updates, updates}}, socket)
    # Only the children read the value; the root's inputs are unchanged.
    refute_receive :root_rendered

    assert socket.assigns._filament_rendered |> Safe.to_iodata() |> IO.iodata_to_binary() ==
             "<section>wrapper<span>10/0</span><span>10/0</span></section>"

    [child | _] = socket.assigns._filament_tree["root"].children
    {:ok, socket} = Filament.LiveComponent.update(%{filament_msg: {:filament_set_state, child, 1, 7}}, socket)
    refute_receive :root_rendered
    html = socket.assigns._filament_rendered |> Safe.to_iodata() |> IO.iodata_to_binary()
    assert html =~ "<section>wrapper"
    assert html =~ "<span>10/7</span>"
    assert html =~ "<span>10/0</span>"

    assert {:ok, ^socket} =
             Filament.LiveComponent.update(
               %{filament_msg: {:cell_updates, [{{self(), "missing", 0}, 99}]}},
               socket
             )

    refute_receive :root_rendered
  end
end
