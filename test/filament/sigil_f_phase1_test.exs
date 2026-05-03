defmodule Filament.SigilFPhase1Test do
  use ExUnit.Case, async: true

  import Filament.SigilF
  import Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Rendered

  describe "~F sigil Phase 1: basic functionality" do
    test "static template produces Rendered struct" do
      result = ~F"""
      <div>hello</div>
      """

      assert %Rendered{} = result
      assert is_list(result.static)
      assert result.static == ["<div>hello</div>"]
      assert is_function(result.dynamic)
    end

    test "template with one interpolation" do
      assigns = %{text: "world"}

      result = ~F"""
      <p>{@text}</p>
      """

      assert %Rendered{} = result
      assert is_function(result.dynamic)
    end

    test "fingerprint is generated" do
      assigns = %{text: "test"}

      result = ~F"""
      <div>Stable {@text}</div>
      """

      assert is_integer(result.fingerprint)
      assert result.fingerprint > 0
    end

    test "different templates have different fingerprints" do
      result1 = ~F"""
      <div>Template 1</div>
      """

      result2 = ~F"""
      <div>Template 2</div>
      """

      assert result1.fingerprint != result2.fingerprint
    end

    test "template with multiple interpolations" do
      assigns = %{name: "Alice", count: 42}

      result = ~F"""
      <div>
        <h1>Hello {@name}</h1>
        <p>You have {@count} items</p>
      </div>
      """

      assert %Rendered{} = result
      dynamic_result = result.dynamic.(false)
      assert is_list(dynamic_result)
      assert length(dynamic_result) == 2
    end

    test "element with event handler attribute compiles" do
      # on_click triggers event_at, which requires a fiber context.
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

      {tree, rendered, _} =
        Filament.Reconciler.mount(EventHandlerComp.EventHandler, %{}, owner_pid: self())

      assert %Rendered{} = rendered
      assert is_function(rendered.dynamic)
      assert Filament.FiberTree.get_event_handler(tree, "root", 0)
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

      {tree, rendered, _} = Filament.Reconciler.mount(OnChangeComp.OnChange, %{}, owner_pid: self())
      assert Enum.any?(rendered.static, &String.contains?(&1, "phx-change"))
      assert Filament.FiberTree.get_event_handler(tree, "root", 0)
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

      {tree, rendered, _} = Filament.Reconciler.mount(OnBlurComp.OnBlur, %{}, owner_pid: self())
      assert Enum.any?(rendered.static, &String.contains?(&1, "phx-blur"))
      assert Filament.FiberTree.get_event_handler(tree, "root", 0)
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

      {tree, rendered, _} = Filament.Reconciler.mount(OnKeydownComp.OnKeydown, %{}, owner_pid: self())
      assert Enum.any?(rendered.static, &String.contains?(&1, "phx-keydown"))
      assert Filament.FiberTree.get_event_handler(tree, "root", 0)
    end

    test "wire output matches ~H for static HTML" do
      assigns = %{}

      filament_result = ~F"""
      <div class="test"><span>Content</span></div>
      """

      heex_result = ~H"""
      <div class="test"><span>Content</span></div>
      """

      filament_iodata = Safe.to_iodata(filament_result)
      heex_iodata = Safe.to_iodata(heex_result)

      assert filament_iodata == heex_iodata
    end
  end
end
