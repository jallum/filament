defmodule Filament.RendererSlotTest do
  @moduledoc """
  opi-lzr.4: Renderer.walk_vnode/2 resolution of {:slot, ...} nodes.

  Unit tests cover the three resolution cases (empty/no-default, empty/with-default,
  filled). Integration test runs the full compile→render pipeline with real components.
  """
  use ExUnit.Case, async: true

  alias Filament.Fiber
  alias Filament.RenderContext
  alias Filament.Renderer
  alias Filament.Slot.Entry

  # Minimal context for unit tests that don't touch components.
  defp stub_ctx do
    %RenderContext{fiber_id: "root", fiber_tree: %{}}
  end

  # ── unit tests ────────────────────────────────────────────────────────────────

  describe "walk_vnode {:slot, ...}" do
    test "empty slot with no default → {:fragment, []}" do
      assert {:fragment, []} = Renderer.walk_vnode({:slot, :header, [], nil}, stub_ctx())
    end

    test "slot with entries → fragment containing walked children" do
      entries = [%Entry{render_fn: fn -> {:text, "Title"} end}]
      assert {:fragment, [{:text, "Title"}]} = Renderer.walk_vnode({:slot, :header, entries, nil}, stub_ctx())
    end

    test "multiple entries each contribute a walked child" do
      entries = [
        %Entry{render_fn: fn -> {:text, "A"} end},
        %Entry{render_fn: fn -> {:text, "B"} end}
      ]

      assert {:fragment, [{:text, "A"}, {:text, "B"}]} =
               Renderer.walk_vnode({:slot, :items, entries, nil}, stub_ctx())
    end

    test "entry with element vnode is walked recursively" do
      entries = [%Entry{render_fn: fn -> {:element, "span", [], [{:text, "hi"}]} end}]
      assert {:fragment, [{:element, "span", [], [{:text, "hi"}]}]} =
               Renderer.walk_vnode({:slot, :body, entries, nil}, stub_ctx())
    end

    test "entries take precedence over default when both present" do
      entries = [%Entry{render_fn: fn -> {:text, "provided"} end}]

      assert {:fragment, [{:text, "provided"}]} =
               Renderer.walk_vnode({:slot, :footer, entries, String}, stub_ctx())
    end
  end

  # ── integration: full compile → render pipeline ───────────────────────────────

  defmodule Panel do
    @moduledoc false
    use Filament.Component

    defcomponent Panel do
      slot :header, required: false
      slot :body, required: true

      def render(assigns) do
        import Filament.Component
        ~F"""
        <div class="panel">
          <:header />
          <:body />
        </div>
        """
      end
    end
  end

  defmodule DefaultPanel do
    @moduledoc false
    use Filament.Component

    defmodule DefaultHeader do
      @moduledoc false
      use Filament.Component

      defcomponent DefaultHeader do
        def render(_) do
          import Filament.Component
          ~F"<span>Default</span>"
        end
      end
    end

    defcomponent DefaultPanel do
      slot :header, required: false, default: DefaultHeader.DefaultHeader
      slot :body, required: true

      def render(assigns) do
        import Filament.Component
        ~F"""
        <div>
          <:header default={Filament.RendererSlotTest.DefaultPanel.DefaultHeader.DefaultHeader} />
          <:body />
        </div>
        """
      end
    end
  end

  defp root_ctx do
    root_fiber = Fiber.new(id: "root", component: __MODULE__)

    %RenderContext{
      fiber_id: "root",
      fiber_tree: %{"root" => root_fiber},
      new_fibers: %{},
      pending_effects: [],
      subscribe_enabled: false
    }
  end

  describe "integration: Panel component with slots" do
    test "body slot entry is rendered into the vnode tree" do
      body_entry = %Entry{render_fn: fn -> {:element, "p", [], [{:text, "Content"}]} end}
      props = %{body: [body_entry]}

      {walked, _, _, _, _, _, _, _} = Renderer.render(Panel.Panel, props, root_ctx())

      # The walked vnode should contain the slot content somewhere in its tree
      assert vnode_contains?(walked, {:element, "p", [], [{:text, "Content"}]})
    end

    test "absent optional slot renders as empty fragment" do
      body_entry = %Entry{render_fn: fn -> {:text, "body"} end}
      props = %{body: [body_entry]}

      {walked, _, _, _, _, _, _, _} = Renderer.render(Panel.Panel, props, root_ctx())

      # No header provided — the header slot should be an empty fragment
      assert vnode_contains?(walked, {:fragment, []})
    end

    test "default module is rendered when slot is absent" do
      body_entry = %Entry{render_fn: fn -> {:text, "body"} end}
      props = %{body: [body_entry]}

      {walked, _, _, _, _, _, _, _} = Renderer.render(DefaultPanel.DefaultPanel, props, root_ctx())

      # DefaultHeader.DefaultHeader should appear as a rendered component child in the tree
      assert vnode_has_component?(walked, DefaultPanel.DefaultHeader.DefaultHeader)
    end
  end

  # Shallow vnode tree search helpers

  defp vnode_contains?(node, target) when node == target, do: true

  defp vnode_contains?({:element, _, _, children}, target),
    do: Enum.any?(children, &vnode_contains?(&1, target))

  defp vnode_contains?({:fragment, children}, target),
    do: Enum.any?(children, &vnode_contains?(&1, target))

  defp vnode_contains?({:component, _, _, _, child}, target),
    do: vnode_contains?(child, target)

  defp vnode_contains?(_, _), do: false

  defp vnode_has_component?({:component, mod, _, _, _}, target) when mod == target, do: true

  defp vnode_has_component?({:element, _, _, children}, target),
    do: Enum.any?(children, &vnode_has_component?(&1, target))

  defp vnode_has_component?({:fragment, children}, target),
    do: Enum.any?(children, &vnode_has_component?(&1, target))

  defp vnode_has_component?({:component, _, _, _, child}, target),
    do: vnode_has_component?(child, target)

  defp vnode_has_component?(_, _), do: false
end
