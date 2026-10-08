defmodule Filament.LiveViewDispatchTest do
  @moduledoc """
  Phase 3.3: `Filament.LiveView.dispatch_filament_event/3` routes through
  `Filament.Core.dispatch_event/4`, so capture handlers on ancestor fibers
  fire root-to-target before the target's handler — purely a wiring test.
  """
  use ExUnit.Case, async: false

  alias Filament.Experimental.Hooks, as: ExperimentalHooks
  alias Filament.LiveView
  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket

  defp socket(assigns) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns),
      private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
    }
  end

  test "capture handler on ancestor fires before target's handler" do
    parent_capture = fn _ -> send(self(), {:capture, :parent}) end
    target_handler = fn _ -> send(self(), {:target}) end

    parent =
      Filament.Fiber.new(
        id: "root",
        component: __MODULE__,
        capture_handlers: %{0 => {parent_capture, :all}}
      )

    leaf =
      Filament.Fiber.new(
        id: "root.leaf",
        component: __MODULE__,
        parent_id: "root",
        event_handlers: %{0 => {target_handler, :all}}
      )

    tree = %{"root" => parent, "root.leaf" => leaf}

    sock =
      socket(%{
        _filament_tree: tree,
        _filament_rendered: {:safe, []},
        _filament_pending_effects: []
      })

    assert {:noreply, _} =
             LiveView.dispatch_filament_event("root.leaf:0", %{key: "x"}, sock)

    assert_received {:capture, :parent}
    assert_received {:target}
  end

  test "missing target handler is a no-op (returns the socket unchanged)" do
    tree = %{
      "root" =>
        Filament.Fiber.new(
          id: "root",
          component: __MODULE__,
          event_handlers: %{}
        )
    }

    sock = socket(%{_filament_tree: tree})

    assert {:noreply, returned} = LiveView.dispatch_filament_event("root:0", %{}, sock)
    assert returned == sock
  end

  test "a stale ref fires no ancestor capture handlers" do
    parent =
      Filament.Fiber.new(
        id: "root",
        component: __MODULE__,
        capture_handlers: %{0 => {fn _ -> send(self(), :captured) end, :all}}
      )

    leaf = Filament.Fiber.new(id: "root.leaf", component: __MODULE__, parent_id: "root", event_handlers: %{})
    sock = socket(%{_filament_tree: %{"root" => parent, "root.leaf" => leaf}})

    assert {:noreply, ^sock} = LiveView.dispatch_filament_event("root.leaf:0", %{}, sock)
    refute_received :captured
  end

  defmodule PushComp do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        ref = ExperimentalHooks.use_event_ref(fn params, push -> push.("echo", params) end)

        ~F"""
        <button phx-click={ref}>go</button>
        """
      end
    end
  end

  test "Filament.Test runs a handler taking a push function" do
    view = Filament.Test.mount!(PushComp, %{})
    assert {:ok, _view} = Filament.Test.click(view, "button")
    assert_received {:push_event, "filament:root:0:echo", %{}}
  end
end
