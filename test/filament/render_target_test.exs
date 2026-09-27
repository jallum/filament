defmodule Filament.RenderTargetTest do
  use ExUnit.Case, async: true

  alias Filament.Core
  alias Filament.Hooks
  alias Filament.Reconciler
  alias Filament.Renderer
  alias Filament.Slot.Entry
  alias Filament.Web
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  defmodule Row do
    @moduledoc false
    def render(%{id: id}) do
      {value, setter} = Hooks.use_state(id)
      {:element, "button", [{"data-id", id}, {"on_click", fn -> setter.(value + 1) end}], [value]}
    end
  end

  defmodule Scalar do
    @moduledoc false
    def render(%{value: value}), do: value
  end

  defmodule Default do
    @moduledoc false
    def render(_), do: {:element, "i", [], [{:text, "default"}]}
  end

  defmodule Root do
    @moduledoc false
    def __props__, do: [ids: %{default: [1]}]

    def render(%{ids: ids}) do
      Hooks.register_event_handler(fn _ -> send(self(), :captured) end, :capture)

      {:element, "section", [{"class", ["a", nil, "b"]}, {"hidden", false}],
       [
         {:text, "literal"},
         "<escaped>",
         [?A, [?B]],
         {:safe, "<strong>safe</strong>"},
         {:slot, :empty, [], nil},
         {:slot, :default, [], Default},
         {:slot, :filled, [%Entry{render_fn: fn -> {:component, Scalar, %{value: "<scalar>"}, nil} end}], nil},
         {:fragment, Enum.map(ids, &{:component, Row, %{id: &1}, &1})}
       ]}
    end
  end

  defmodule RootLiveView do
    use Filament.LiveView

    def root_component, do: Root
  end

  defmodule RecordingTarget do
    @moduledoc false
    @behaviour Filament.RenderTarget

    def render(output, context) do
      send(self(), {:target, context.fiber_id, context.target})
      if is_tuple(output), do: Renderer.walk_vnode(output, context), else: output
    end
  end

  defmodule Broken do
    @moduledoc false
    def render(_), do: {:unexpected, :node}
  end

  defp socket do
    %Socket{
      assigns: %{__changed__: %{}},
      private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
    }
  end

  defp shape(%Rendered{} = rendered) do
    {rendered.static, Enum.map(rendered.dynamic.(false), &shape/1), rendered.fingerprint}
  end

  defp shape(value), do: value

  defp html(rendered), do: rendered |> Safe.to_iodata() |> IO.iodata_to_binary()

  test "direct target matches portable output, fingerprints and incremental client HTML" do
    props = %{ids: [1, 2, 3]}
    {portable_tree, portable, []} = Reconciler.mount(Root, props, owner_pid: self())
    {direct_tree, direct, []} = Reconciler.mount(Root, props, owner_pid: self(), target: Web)
    portable = Web.to_rendered(portable)
    assert shape(direct) == shape(portable)
    assert Map.keys(direct_tree) == Map.keys(portable_tree)
    assert html(direct) =~ "AB"
    assert html(direct) =~ "&lt;escaped&gt;"
    assert html(direct) =~ "<strong>safe</strong>"
    assert html(direct) =~ "&lt;scalar&gt;"

    {initial, prints, components} = Diff.render(socket(), direct, Diff.new_fingerprints(), Diff.new_components())
    client = Phoenix.LiveViewTest.Diff.merge_diff(%{}, initial)
    props = %{ids: [3, 1, 4]}
    {next_portable_tree, next_portable, []} = Reconciler.update(portable_tree, "root", props, owner_pid: self())
    {next_direct_tree, next_direct, []} = Reconciler.update(direct_tree, "root", props, owner_pid: self(), target: Web)
    assert shape(next_direct) == shape(Web.to_rendered(next_portable))
    assert Map.keys(next_direct_tree) == Map.keys(next_portable_tree)

    for {id, fiber} <- direct_tree, fiber.props[:id] in [1, 3] do
      assert elem(next_direct_tree[id].hook_slots[0], 0) == fiber.props.id
    end

    {diff, _, _} = Diff.render(socket(), next_direct, prints, components)
    merged = Phoenix.LiveViewTest.Diff.merge_diff(client, diff)
    assert IO.iodata_to_binary(Diff.to_iodata(merged)) == html(next_direct)
    Reconciler.unmount(next_portable_tree, owner_pid: self())
    Reconciler.unmount(next_direct_tree, owner_pid: self())
  end

  test "LiveView target preserves capture, wire refs and a child state update" do
    {:ok, mounted} = RootLiveView.mount(%{}, %{}, Phoenix.Component.assign(socket(), :props, %{ids: [1]}))

    [{ref, _}] =
      mounted.assigns._filament_rendered
      |> html()
      |> Floki.parse_fragment!()
      |> Floki.find("button")
      |> Enum.map(fn button -> {hd(Floki.attribute(button, "phx-click")), button} end)

    assert "filament:" <> wire_ref = ref
    {:noreply, dispatched} = RootLiveView.handle_event("filament:" <> wire_ref, %{}, mounted)
    assert_receive :captured
    assert_receive {:filament_set_state, fid, slot, 2} = message
    assert {:ok, :dispatched} = Core.dispatch_event(dispatched.assigns._filament_tree, fid, slot, %{}, :click)
    assert_receive :captured
    assert_receive {:filament_set_state, ^fid, ^slot, 2}
    {:noreply, updated} = RootLiveView.handle_info(message, dispatched)
    assert html(updated.assigns._filament_rendered) =~ ">2</button>"
    Reconciler.unmount(updated.assigns._filament_tree, owner_pid: self())
  end

  test "child contexts inherit an arbitrary target" do
    {tree, _output, []} = Reconciler.mount(Root, %{ids: [1]}, target: RecordingTarget)
    assert_receive {:target, "root", RecordingTarget}

    for {id, _fiber} <- tree, id != "root" do
      assert_receive {:target, ^id, RecordingTarget}
    end

    assert Renderer.current_context() == nil
  end

  test "an adapter failure clears render context" do
    assert_raise ArgumentError, fn -> Reconciler.mount(Broken, %{}, target: Web) end
    assert Renderer.current_context() == nil
  end
end
