defmodule Filament.TemplateTest do
  use ExUnit.Case, async: true

  alias Filament.Reconciler
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Comprehension
  alias Phoenix.LiveView.Rendered

  defmodule Row do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(props) do
        send(self(), {:rendered, props.id})
        ~F"<li data-id={props.id}>{props.label}</li>"
      end
    end
  end

  defmodule Rows do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(props) do
        ~F"<ul><%= for item <- props.items do %><Filament.TemplateTest.Row :key={item.id} id={item.id} label={item.label} /><% end %></ul>"
      end
    end
  end

  defmodule CountRow do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:id, :integer, required: true)

      def render(%{id: id}) do
        {n, _set_n} = use_state(0)
        ~F|<li data-id={id}>{n}</li>|
      end
    end
  end

  defmodule CountRows do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:ids, :list, required: true)

      def render(%{ids: ids}) do
        ~F"<ul><Filament.TemplateTest.CountRow :for={id <- ids} :key={id} id={id} /></ul>"
      end
    end
  end

  test "a dirty row inside a compiled template renders while its parent is reused" do
    {tree, _, _} = Reconciler.mount(CountRows, %{ids: [1, 2]}, target: Filament.Web, owner_pid: self())
    row = Enum.find(Map.keys(tree), &(&1 =~ "key=1"))
    {:rerender, tree} = Filament.StateHelper.apply_set_state(tree, row, 0, 5)

    {tree, out, _} = Reconciler.update(tree, "root", %{ids: [1, 2]}, target: Filament.Web, owner_pid: self())
    assert html(out) == ~s(<ul><li data-id="1">5</li><li data-id="2">0</li></ul>)
    Reconciler.unmount(tree)
  end

  defmodule Ordering do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_) do
        send(self(), :parent_before)
        output = ~F'<div><Filament.TemplateTest.Row id={1} label="one" /></div>'
        send(self(), :parent_after)
        output
      end
    end
  end

  defmodule Attributes do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(props), do: ~F"<button disabled={props.disabled} class={props.class}>{props.label}</button>"
    end
  end

  defmodule Opaque do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(props), do: ~F"<div>{props.child}</div>"
    end
  end

  defp html(rendered), do: rendered |> Filament.Web.to_rendered() |> Safe.to_iodata() |> IO.iodata_to_binary()

  test "child rendering still happens after the complete parent render" do
    for options <- [[], [target: Filament.Web]] do
      {tree, _, []} = Reconciler.mount(Ordering, %{}, options)

      for expected <- [:parent_before, :parent_after, {:rendered, 1}] do
        assert_receive actual
        assert actual == expected
      end

      Reconciler.unmount(tree)
    end
  end

  test "Web plans preserve portable HTML for dynamic attributes, escaping and fallbacks" do
    for disabled <- [nil, false, true, "disabled"], class <- ["a & b", ["a", nil, false, "b"]] do
      props = %{disabled: disabled, class: class, label: "<hello>"}
      {portable_tree, portable, []} = Reconciler.mount(Attributes, props)
      {web_tree, web, []} = Reconciler.mount(Attributes, props, target: Filament.Web)
      assert is_tuple(portable)
      assert %Rendered{} = web
      assert html(web) == html(portable)
      Reconciler.unmount(portable_tree)
      Reconciler.unmount(web_tree)
    end
  end

  test "keyed collection reuses templates and rows whose props are unchanged" do
    items = [%{id: 1, label: "one"}, %{id: 2, label: "two"}]
    {tree, initial, []} = Reconciler.mount(Rows, %{items: items}, target: Filament.Web)
    assert_receive {:rendered, 1}
    assert_receive {:rendered, 2}
    assert [%Comprehension{has_key?: true}] = initial.dynamic.(false)
    {moved_tree, moved, []} = Reconciler.update(tree, "root", %{items: Enum.reverse(items)}, target: Filament.Web)
    refute_received {:rendered, _}
    assert Map.keys(tree) == Map.keys(moved_tree)
    assert html(moved) == ~s(<ul><li data-id="2">two</li><li data-id="1">one</li></ul>)
    {empty_tree, empty, []} = Reconciler.update(moved_tree, "root", %{items: []}, target: Filament.Web)
    assert html(empty) == "<ul></ul>"
    {filled_tree, filled, []} = Reconciler.update(empty_tree, "root", %{items: items}, target: Filament.Web)
    assert html(filled) == html(initial)
    Reconciler.unmount(filled_tree)
  end

  test "nested opaque Rendered output preserves eager evaluation on every render" do
    dynamic = fn _track ->
      send(self(), :encoded)
      [Process.get(:template_value)]
    end

    child = %Rendered{static: ["<span>", "</span>"], dynamic: dynamic, fingerprint: 123, root: false}
    Process.put(:template_value, "before")
    {tree, first, []} = Reconciler.mount(Opaque, %{child: [{:element, "section", [], [child]}]}, target: Filament.Web)
    assert_receive :encoded
    refute_received :encoded
    assert html(first) == "<div><section><span>before</span></section></div>"
    refute_received :encoded
    Process.put(:template_value, "after")

    {updated, second, []} =
      Reconciler.update(tree, "root", %{child: [{:element, "section", [], [child]}]}, target: Filament.Web)

    assert_receive :encoded
    refute_received :encoded
    assert html(second) == "<div><section><span>after</span></section></div>"
    refute_received :encoded
    Reconciler.unmount(updated)
  end

  defmodule SwitchRow do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(props), do: ~F|<li>{props.label}</li>|
    end
  end

  defmodule Switch do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def item(label), do: ~F|<li>{label}</li>|
      def render(%{items: nil, label: label}), do: ~F|<ul>{item(label)}</ul>|

      def render(%{items: items}),
        do: ~F|<ul><Filament.TemplateTest.SwitchRow :for={i <- items} :key={i} label={i} /></ul>|
    end
  end

  test "a slot that switches between a keyed list and a row with the same markup patches the client" do
    for [first, second] <- [
          [%{items: ["a", "b"], label: nil}, %{items: nil, label: "s"}],
          [%{items: nil, label: "s"}, %{items: ["a", "b"], label: nil}]
        ] do
      assert {html, html} = client_after(Switch, first, second)
    end
  end

  defmodule TitleRow do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(props), do: ~F|<li title={props.title}>{props.label}</li>|
    end
  end

  defmodule TitleRows do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(props),
        do:
          ~F|<ul><Filament.TemplateTest.TitleRow :for={i <- props.items} :key={i.id} title={i.title} label={i.title} /></ul>|
    end
  end

  test "a keyed row patches the client when a value changes between raw and safe with equal content" do
    row = fn value -> %{items: [%{id: 1, title: value}]} end

    for [first, second] <- [[row.("a&b"), row.({:safe, "a&b"})], [row.({:safe, "a&amp;b"}), row.("a&amp;b")]] do
      assert {html, html} = client_after(TitleRows, first, second)
    end
  end

  # The client's HTML after applying both diffs, and the server's.
  defp client_after(component, first, second) do
    alias Phoenix.LiveView.Diff
    alias Phoenix.LiveViewTest.Diff, as: Client

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}, private: %{live_temp: %{}}}
    {tree, r1, _} = Reconciler.mount(component, first, target: Filament.Web)
    {d1, prints, components} = Diff.render(socket, r1, Diff.new_fingerprints(), Diff.new_components())
    {tree, r2, _} = Reconciler.update(tree, "root", second, target: Filament.Web)
    {d2, _, _} = Diff.render(socket, r2, prints, components)
    Reconciler.unmount(tree)

    {%{} |> Client.merge_diff(d1) |> Client.merge_diff(d2) |> Diff.to_iodata() |> IO.iodata_to_binary(), html(r2)}
  end
end
