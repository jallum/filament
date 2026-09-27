defmodule Filament.BitstringCaptureTest do
  use ExUnit.Case, async: true

  alias Filament.FiberTree
  alias Filament.Reconciler
  alias Phoenix.HTML.Safe

  for {name, template} <- [
        same_element: ~S|<li :for={x <- items} class={"item-#{x}-#{suffix}"} on_click={fn -> nil end}>{x}</li>|,
        child_class:
          ~S|<li :for={x <- items} on_click={fn -> nil end}><span class={"item-#{x}-#{suffix}"}>{x}</span></li>|,
        child_handler:
          ~S|<li :for={x <- items} class={"item-#{x}-#{suffix}"}><span on_click={fn -> nil end}>{x}</span></li>|
      ] do
    @template template
    test "interpolated class with handler: #{name}" do
      component = compile_component(@template, "items: items, suffix: suffix")
      props = %{items: ["a", "b"], suffix: "first"}
      {tree, rendered, _} = Reconciler.mount(component, props, owner_pid: self())
      assert html(rendered) =~ ~s(class="item-a-first")
      assert html(rendered) =~ ~s(class="item-b-first")
      assert FiberTree.get_event_handler(tree, "root", 0).() == nil

      {_, rendered, _} = Reconciler.update(tree, "root", %{props | suffix: "next"}, owner_pid: self())
      assert html(rendered) =~ ~s(class="item-a-next")
    end
  end

  test "bitstring size variables remain dependencies in loop handlers" do
    component =
      compile_component(
        ~S|<li :for={x <- items} on_click={fn -> <<x::integer-size(width)-unit(1)>> end}>{x}</li>|,
        "items: items, width: width"
      )

    {tree, _, _} = Reconciler.mount(component, %{items: [65], width: 8}, owner_pid: self())
    assert FiberTree.get_event_handler(tree, "root", 0).() == "A"
    {tree, _, _} = Reconciler.update(tree, "root", %{items: [65], width: 16}, owner_pid: self())
    assert FiberTree.get_event_handler(tree, "root", 0).() == <<0, 65>>
  end

  defp compile_component(template, pattern) do
    module = Module.concat(__MODULE__, "Repro#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Filament.Component
      defcomponent do
        def render(%{#{pattern}}) do
          ~F|<ul>#{template}</ul>|
        end
      end
    end
    """)

    module
  end

  defp html(rendered), do: rendered |> Safe.to_iodata() |> IO.iodata_to_binary()
end
