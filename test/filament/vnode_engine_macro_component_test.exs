defmodule Filament.VNodeEngineMacroComponentTest do
  @moduledoc """
  Phase 1.4.6: macro components such as `<script :type={Phoenix.LiveView.ColocatedHook}>`
  must compile cleanly under `Filament.VNodeEngine`. The transform happens at
  compile time (Phoenix.Component.MacroComponent picks up the `:type` attr,
  collects the JS body into a manifest, and rewrites the AST). This ticket
  verifies the post-transform AST flows through structured emission and the
  resulting vnode tree contains everything except the stripped `<script>` tag.
  """
  use ExUnit.Case, async: true

  alias Filament.RenderContext
  alias Filament.Renderer
  alias Filament.Web

  defmodule Fixture do
    @moduledoc false
    use Filament.Component

    import Filament.Test.VNodeEngineHelper

    def template do
      vnode_template("""
      <div>
        <span phx-hook=".VNodeHook" id="vnode-el"></span>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".VNodeHook">
          export default { mounted() {} }
        </script>
      </div>
      """)
    end
  end

  test "colocated hook script tag is stripped, surrounding elements emit correctly" do
    vnode = Fixture.template()

    ctx = %RenderContext{fiber_id: "root", fiber_tree: %{}, new_fibers: %{}, pending_effects: []}
    Process.put(:filament_render_context, ctx)
    walked = Renderer.walk_vnode(vnode, ctx)
    Process.delete(:filament_render_context)

    html = walked |> Web.to_iodata() |> IO.iodata_to_binary()

    refute html =~ "<script", "colocated hook <script> tag should be stripped from output"
    # The colocated-hook transform rewrites `.VNodeHook` to a fully-qualified
    # name based on the caller module, so we just confirm `phx-hook=` and the
    # `VNodeHook` suffix survive into the output.
    assert html =~ "phx-hook=\""
    assert html =~ "VNodeHook"
    assert html =~ ~s(id="vnode-el")
  end
end
