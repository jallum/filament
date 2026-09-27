defmodule Filament.AdapterCaptureTest do
  use ExUnit.Case, async: true

  defmodule Target do
    @moduledoc false
    use Filament.Component

    def render(%{observer: observer}) do
      {count, set_count} = use_state(0)
      ~F"<button on_click={fn -> send(observer, :target); set_count.(count + 1) end}>{count}</button>"
    end
  end

  defmodule Middle do
    @moduledoc false
    use Filament.Component

    def render(%{observer: observer, stop: stop} = props) do
      Filament.Hooks.register_event_handler(
        fn ->
          send(observer, :middle)
          if stop, do: Filament.Core.stop_propagation(:blocked)
        end,
        :capture
      )

      {:component, Target, props, nil}
    end
  end

  defmodule Root do
    @moduledoc false
    use Filament.Component

    def render(%{observer: observer} = props) do
      Filament.Hooks.register_event_handler(fn -> send(observer, :root) end, :capture)
      {:component, Middle, props, nil}
    end
  end

  for adapter <- [Filament.LiveView, Filament.LiveComponent] do
    test "#{adapter} honors capture order, stop propagation, and state setters" do
      for stop <- [true, false] do
        {tree, _, _} = Filament.Reconciler.mount(Root, %{observer: self(), stop: stop}, owner_pid: self())
        {child, _} = Enum.find(tree, fn {_, fiber} -> fiber.component == Target end)
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, _filament_tree: tree}}
        ref = "#{child}:0"

        case unquote(adapter) do
          Filament.LiveView ->
            assert {:noreply, ^socket} = Filament.LiveView.dispatch_filament_event(ref, %{}, socket)

          Filament.LiveComponent ->
            assert {:noreply, ^socket} = Filament.LiveComponent.handle_event("filament:" <> ref, %{}, socket)
        end

        assert_receive :root
        assert_receive :middle

        if stop do
          refute_receive :target
          refute_receive {:filament_set_state, _, _, _}
        else
          assert_receive :target
          assert_receive {:filament_set_state, ^child, 0, 1}
        end
      end
    end
  end

  test "isolated click uses the same propagation model and flushes state updates" do
    for stop <- [true, false] do
      view = Filament.Test.mount!(Root, %{observer: self(), stop: stop})
      {:ok, view} = Filament.Test.click(view, "button")
      assert_receive :root
      assert_receive :middle

      if stop do
        refute_receive :target
        assert Filament.Test.render_text(view) == "0"
      else
        assert_receive :target
        assert Filament.Test.render_text(view) == "1"
      end

      stale = %{view | fiber_tree: %{}}
      assert {:error, {:stale_handler, _}} = Filament.Test.click(stale, "button")
    end
  end
end
