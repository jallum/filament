defmodule Filament.LiveComponentTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket

  defp test_socket(assigns \\ %{}) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      private: %{
        live_temp: %{},
        lifecycle: Phoenix.LiveView.Lifecycle.__struct__()
      }
    }
  end

  defmodule LabelComp do
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

      assert socket.assigns._filament_tree != nil
      rendered = socket.assigns._filament_rendered
      assert %Phoenix.LiveView.Rendered{} = rendered

      html = Phoenix.HTML.Safe.to_iodata(rendered) |> IO.iodata_to_binary()
      assert html =~ "World"
    end

    test "props are passed to the component" do
      {:ok, socket} = Filament.LiveComponent.mount(test_socket())
      assigns = %{id: "t", component: LabelComp, label: "Custom"}
      {:ok, socket} = Filament.LiveComponent.update(assigns, socket)

      html =
        socket.assigns._filament_rendered
        |> Phoenix.HTML.Safe.to_iodata()
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
        |> Phoenix.HTML.Safe.to_iodata()
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
end
