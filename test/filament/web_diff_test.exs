defmodule Filament.WebDiffTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveView.Socket

  defp initial(walked) do
    socket = %Socket{assigns: %{__changed__: %{}}, private: %{live_temp: %{}}}
    rendered = Filament.Web.to_rendered(walked)
    {diff, prints, components} = Diff.render(socket, rendered, Diff.new_fingerprints(), Diff.new_components())
    {socket, diff, prints, components}
  end

  test "a changed static wire reference is sent to the browser" do
    button = fn ref -> {:element, "button", [{"on_click", {:wire_ref, ref}}], []} end
    {socket, first, prints, components} = initial(button.("root:0"))
    assert first.s == [~s(<button phx-click="filament:root:0"></button>)]
    {second, _, _} = Diff.render(socket, Filament.Web.to_rendered(button.("root:1")), prints, components)
    assert second.s == [~s(<button phx-click="filament:root:1"></button>)]
  end

  test "inserting and removing a safe child updates the dynamic layout" do
    base = {:element, "p", [], ["left", "right"]}
    inserted = {:element, "p", [], ["left", {:safe, "<b>middle</b>"}, "right"]}
    {socket, _, prints, components} = initial(base)
    {diff, prints, components} = Diff.render(socket, Filament.Web.to_rendered(inserted), prints, components)
    assert diff.s == ["<p>", "", "", "</p>"]
    assert diff[0] == "left"
    assert diff[1] == "<b>middle</b>"
    assert diff[2] == "right"
    {removed, _, _} = Diff.render(socket, Filament.Web.to_rendered(base), prints, components)
    assert removed.s == ["<p>", "", "</p>"]
    assert removed[1] == "right"
  end
end
