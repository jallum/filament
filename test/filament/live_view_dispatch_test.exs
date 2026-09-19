defmodule Filament.LiveViewDispatchTest do
  @moduledoc """
  Phase 3.3: `Filament.LiveView.dispatch_filament_event/3` routes through
  `Filament.Core.dispatch_event/4`, so capture handlers on ancestor fibers
  fire root-to-target before the target's handler — purely a wiring test.
  """
  use ExUnit.Case, async: false

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
        capture_handlers: %{0 => parent_capture}
      )

    leaf =
      Filament.Fiber.new(
        id: "root.leaf",
        component: __MODULE__,
        parent_id: "root",
        event_handlers: %{0 => target_handler}
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
end
