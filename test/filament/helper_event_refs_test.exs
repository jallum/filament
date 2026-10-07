defmodule Filament.HelperEventRefsTest do
  use ExUnit.Case, async: true

  alias Filament.Test, as: ComponentTest
  alias Phoenix.HTML.Safe

  defmodule Buttons do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(%{before: before?, helper: helper?}) do
        {clicked, set_clicked} = use_state("none")
        early = if before?, do: helper(set_clicked, "early")

        ~F"""
        <p>{clicked}</p>
        {early}
        <button class="main" on_click={fn -> set_clicked.("main") end}>Main</button>
        {if helper?, do: helper(set_clicked, "helper")}
        {helper(set_clicked, "last")}
        """
      end

      defp helper(set_clicked, label),
        do: ~F|<button class={label} on_click={fn -> set_clicked.(label) end}>{label}</button>|
    end
  end

  defmodule LoopButtons do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_) do
        {clicked, set_clicked} = use_state("none")

        ~F"""
        <p>{clicked}</p>
        <button :for={n <- [1, 2]} class={"row#{n}"} on_click={fn -> set_clicked.("row#{n}") end}>{n}</button>
        {helper(set_clicked)}
        """
      end

      defp helper(set_clicked), do: ~F|<button class="last" on_click={fn -> set_clicked.("last") end}>Last</button>|
    end
  end

  test "memoized loop handler replay reserves its range before a following helper" do
    view = ComponentTest.mount!(LoopButtons, %{})
    view = ComponentTest.click!(view, "button.last")
    assert view |> ComponentTest.render_text() |> String.starts_with?("last")
    view = ComponentTest.click!(view, "button.row1")
    assert view |> ComponentTest.render_text() |> String.starts_with?("row1")
    view = ComponentTest.click!(view, "button.row2")
    assert view |> ComponentTest.render_text() |> String.starts_with?("row2")
    view = ComponentTest.click!(view, "button.last")
    assert view |> ComponentTest.render_text() |> String.starts_with?("last")
    Filament.Reconciler.unmount(view.fiber_tree, owner_pid: self())
  end

  test "helper refs and closures remain independent before, within and across templates" do
    for before? <- [false, true] do
      view = ComponentTest.mount!(Buttons, %{before: before?, helper: true})
      selectors = if before?, do: ["early", "main", "helper", "last"], else: ["main", "helper", "last"]

      for selector <- selectors do
        view = ComponentTest.click!(view, "button." <> selector)
        assert view |> ComponentTest.render_text() |> String.starts_with?(selector)
      end

      refs = ~r/phx-click="([^"]+)"/ |> Regex.scan(view.rendered_html, capture: :all_but_first) |> List.flatten()
      assert length(Enum.uniq(refs)) == length(selectors)
      Filament.Reconciler.unmount(view.fiber_tree, owner_pid: self())
    end
  end

  test "conditional helper removal invalidates moved memoized refs" do
    view = ComponentTest.mount!(Buttons, %{before: true, helper: true})
    view = ComponentTest.click!(view, "button.last")

    {tree, rendered, []} =
      Filament.Reconciler.update(view.fiber_tree, "root", %{before: false, helper: false}, owner_pid: self())

    view = %{
      view
      | props: %{before: false, helper: false},
        fiber_tree: tree,
        rendered_html: rendered |> Safe.to_iodata() |> IO.iodata_to_binary()
    }

    view = ComponentTest.click!(view, "button.main")
    assert view |> ComponentTest.render_text() |> String.starts_with?("main")
    view = ComponentTest.click!(view, "button.last")
    assert view |> ComponentTest.render_text() |> String.starts_with?("last")
    Filament.Reconciler.unmount(view.fiber_tree, owner_pid: self())
  end
end
