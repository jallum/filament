defmodule Filament.Core.DispatchEventKindsTest do
  @moduledoc """
  flm-c17: kinds-aware handler registration + dispatch filtering.

  Handlers can declare which kinds of events they want via the kinds-set
  on `register_event_handler/3` (stored on the fiber as
  `event_handler_kinds[slot]`). `Core.dispatch_event/5` takes a `kind` arg;
  handlers whose recorded kinds-set is `:all` (or includes the dispatched
  kind) fire; others are skipped.
  """
  use ExUnit.Case, async: true

  alias Filament.Core
  alias Filament.Fiber

  defp fiber(opts), do: Fiber.new(opts)
  defp tree(fibers), do: Map.new(fibers, &{&1.id, &1})

  describe "bubble-phase handler kind filtering" do
    test ":all kinds-set fires for any kind" do
      handler = fn _ -> send(self(), :fired) end

      t =
        tree([
          fiber(
            id: "root",
            component: __MODULE__,
            event_handlers: %{0 => handler},
            event_handler_kinds: %{0 => :all}
          )
        ])

      assert {:ok, _} = Core.dispatch_event(t, "root", 0, %{}, :press)
      assert_received :fired

      assert {:ok, _} = Core.dispatch_event(t, "root", 0, %{}, :release)
      assert_received :fired
    end

    test "specific kind-set fires only for matching kinds" do
      handler = fn _ -> send(self(), :fired) end

      t =
        tree([
          fiber(
            id: "root",
            component: __MODULE__,
            event_handlers: %{0 => handler},
            event_handler_kinds: %{0 => MapSet.new([:press, :repeat])}
          )
        ])

      assert {:ok, _} = Core.dispatch_event(t, "root", 0, %{}, :press)
      assert_received :fired

      assert {:ok, _} = Core.dispatch_event(t, "root", 0, %{}, :repeat)
      assert_received :fired

      assert {:ok, _} = Core.dispatch_event(t, "root", 0, %{}, :release)
      refute_received :fired
    end

    test "missing kinds-entry defaults to :all (back-compat with fibers built outside this API)" do
      handler = fn _ -> send(self(), :fired) end

      t =
        tree([
          fiber(
            id: "root",
            component: __MODULE__,
            event_handlers: %{0 => handler}
            # no event_handler_kinds at all
          )
        ])

      assert {:ok, _} = Core.dispatch_event(t, "root", 0, %{}, :release)
      assert_received :fired
    end
  end

  describe "capture-phase handler kind filtering" do
    test "specific kind-set on capture handler filters" do
      ancestor_capture = fn _ -> send(self(), :captured) end
      target_handler = fn _ -> send(self(), :target_fired) end

      t =
        tree([
          fiber(
            id: "root",
            component: __MODULE__,
            capture_handlers: %{0 => ancestor_capture},
            capture_handler_kinds: %{0 => MapSet.new([:release])}
          ),
          fiber(
            id: "child",
            component: __MODULE__,
            parent_id: "root",
            event_handlers: %{0 => target_handler}
          )
        ])

      Core.dispatch_event(t, "child", 0, %{}, :press)
      refute_received :captured
      assert_received :target_fired

      Core.dispatch_event(t, "child", 0, %{}, :release)
      assert_received :captured
      assert_received :target_fired
    end
  end

  describe "backwards compatibility" do
    test "4-arity dispatch (no kind) defaults to :all and fires every handler" do
      handler = fn _ -> send(self(), :fired) end

      t =
        tree([
          fiber(
            id: "root",
            component: __MODULE__,
            event_handlers: %{0 => handler},
            event_handler_kinds: %{0 => MapSet.new([:press])}
          )
        ])

      # No kind arg → dispatch as :all → fires regardless of handler's
      # registered kind-set. This preserves today's behavior for callers
      # that haven't adopted kinds yet.
      assert {:ok, _} = Core.dispatch_event(t, "root", 0, %{})
      assert_received :fired
    end
  end
end
