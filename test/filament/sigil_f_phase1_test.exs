defmodule Filament.SigilFPhase1Test do
  use ExUnit.Case, async: true

  import Filament.SigilF

  alias Filament.FiberTree
  alias Filament.Reconciler

  describe "~F sigil Phase 1: basic functionality" do
    test "element with event handler attribute compiles" do
      # on_click triggers event handler registration via the substrate walker.
      # Templates with event handlers must run inside a render pass.
      defmodule EventHandlerComp do
        @moduledoc false
        use Filament.Component

        defcomponent EventHandler do
          def render(_assigns) do
            ~F"""
            <button on_click={fn -> :clicked end}>
              Click me
            </button>
            """
          end
        end
      end

      {tree, walked, _} =
        Reconciler.mount(EventHandlerComp.EventHandler, %{}, owner_pid: self())

      assert is_tuple(walked), "expected mount to return a walked vnode tree"
      assert FiberTree.get_event_handler(tree, "root", 0)
    end

    test "on_change wires to phx-change" do
      defmodule OnChangeComp do
        @moduledoc false
        use Filament.Component

        defcomponent OnChange do
          def render(_assigns) do
            ~F"""
            <input on_change={fn _val -> :changed end} />
            """
          end
        end
      end

      {tree, walked, _} = Reconciler.mount(OnChangeComp.OnChange, %{}, owner_pid: self())
      html = walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary()

      assert html =~ "phx-change=\"filament:root:0\""
      assert FiberTree.get_event_handler(tree, "root", 0)
    end

    test "on_blur wires to phx-blur" do
      defmodule OnBlurComp do
        @moduledoc false
        use Filament.Component

        defcomponent OnBlur do
          def render(_assigns) do
            ~F"""
            <input on_blur={fn -> :blurred end} />
            """
          end
        end
      end

      {tree, walked, _} = Reconciler.mount(OnBlurComp.OnBlur, %{}, owner_pid: self())
      html = walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary()

      assert html =~ "phx-blur=\"filament:root:0\""
      assert FiberTree.get_event_handler(tree, "root", 0)
    end

    test "on_key wires to phx-hook FilamentKey with data-filament-wire and id" do
      defmodule OnKeyComp do
        @moduledoc false
        use Filament.Component

        defcomponent OnKey do
          def render(_assigns) do
            ~F"""
            <div on_key={fn
              "Escape", _ -> :close
              _, _ -> :ignore
            end}>modal</div>
            """
          end
        end
      end

      {tree, walked, _} = Reconciler.mount(OnKeyComp.OnKey, %{}, owner_pid: self())
      html = walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary()

      assert html =~ ~s(phx-hook="FilamentKey"),
             "on_key must emit phx-hook=\"FilamentKey\""

      assert html =~ "data-filament-wire=",
             "on_key must emit data-filament-wire attribute"

      refute html =~ "phx-window-keydown",
             "on_key must not fall back to phx-window-keydown"

      assert html =~ ~r/id="[^"]+"/,
             "on_key element must have an id for the hook"

      handler = FiberTree.get_event_handler(tree, "root", 0)
      assert is_function(handler, 1), "handler must be arity-1"

      assert handler.(%{"key" => "Escape", "ctrl" => false, "shift" => false, "alt" => false, "meta" => false}) == :close
      assert handler.(%{"key" => "Enter", "ctrl" => false, "shift" => false, "alt" => false, "meta" => false}) == :ignore
    end

    test "on_key handler receives key string and %Filament.KeyModifiers{} with modifier fields" do
      defmodule OnKeyModComp do
        @moduledoc false
        use Filament.Component

        defcomponent OnKeyMod do
          def render(_assigns) do
            {last, set_last} = use_state(nil)

            ~F"""
            <div on_key={fn key, mods -> set_last.({key, mods}) end}>{inspect(last)}</div>
            """
          end
        end
      end

      {tree, _walked, _} = Reconciler.mount(OnKeyModComp.OnKeyMod, %{}, owner_pid: self())

      handler = FiberTree.get_event_handler(tree, "root", 0)
      handler.(%{"key" => "s", "ctrl" => true, "shift" => false, "alt" => false, "meta" => false})

      assert_received {:filament_set_state, _, _, {"s", %Filament.KeyModifiers{ctrl: true, shift: false}}}
    end

    test "on_keydown wires to phx-keydown" do
      defmodule OnKeydownComp do
        @moduledoc false
        use Filament.Component

        defcomponent OnKeydown do
          def render(_assigns) do
            ~F"""
            <input on_keydown={fn _key -> :key end} />
            """
          end
        end
      end

      {tree, walked, _} = Reconciler.mount(OnKeydownComp.OnKeydown, %{}, owner_pid: self())
      html = walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary()

      assert html =~ "phx-keydown=\"filament:root:0\""
      assert FiberTree.get_event_handler(tree, "root", 0)
    end
  end
end
