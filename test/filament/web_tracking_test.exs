defmodule Filament.WebTrackingTest do
  @moduledoc """
  Wire updates from a Filament LiveView, as a browser receives them: each diff
  is applied to the previous client state and compared with a fresh render.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveView.Utils
  alias Phoenix.LiveViewTest.Diff, as: Client

  defmodule Row do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:label, :string)
      prop(:test, :any)

      def render(props) do
        {n, set_n} = use_state(0)
        use_effect(fn -> fn -> send(props.test, {:row_cleanup, props.label}) end end, [])
        ~F|<li><button on_click={fn -> set_n.(n + 1) end}>{props.label}</button> {n}</li>|
      end
    end
  end

  defmodule Child do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:text, :string)

      def render(props) do
        {n, set_n} = use_state(0)
        ~F|<p><button on_click={fn -> set_n.(n + 1) end}>child</button> {n} <em>{props.text}</em></p>|
      end
    end
  end

  defmodule Page do
    @moduledoc false
    use Filament.Component

    defcomponent do
      for name <- [:query, :secret, :flag, :text, :mode, :rows, :test], do: prop(name, :any)

      def render(props) do
        ~F"""
        <div>
          <input value={props.query} />
          <button on_click={fn -> send(props.test, {:go, props.secret}) end}>go</button>
          {if props.flag do}<section class="on">{props.query}</section>{else}<aside>off</aside>{end}
          <Filament.WebTrackingTest.Child text={props.text} />
          {case props.mode do}
            {:html -> }<ul><li :for={r <- props.rows} :key={r.id} class="row">{r.label}</li></ul>
            {:unkeyed -> }<ul><li :for={r <- props.rows} class="row">{r.label}</li></ul>
            {:components -> }<ul><Filament.WebTrackingTest.Row :for={r <- props.rows} :key={r.id} label={r.label} test={props.test} /></ul>
          {end}
        </div>
        """
      end

      def handle_event("set", changes, props), do: Map.merge(props, changes)
    end
  end

  defmodule PageLive do
    @moduledoc false
    use Filament.LiveView

    def root_component, do: Page
  end

  defp rows(n), do: for(i <- 1..n, do: %{id: i, label: "row #{i}"})

  defp mount(mode, n \\ 25) do
    assigns = %{
      __changed__: %{},
      query: "a",
      secret: 1,
      flag: true,
      text: "t",
      mode: mode,
      rows: rows(n),
      test: self()
    }

    socket = %Socket{
      transport_pid: self(),
      assigns: assigns,
      private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
    }

    {:ok, socket} = PageLive.mount(%{}, %{}, socket)
    frame(%{socket: socket, prints: Diff.new_fingerprints(), components: Diff.new_components(), client: %{}})
  end

  # Renders one frame: the diff LiveView sends, checked against a fresh render.
  defp frame(view) do
    {diff, prints, components} =
      Diff.render(view.socket, PageLive.render(view.socket.assigns), view.prints, view.components)

    client = Client.merge_diff(view.client, diff)

    fresh =
      Diff.render(
        %{view.socket | assigns: %{view.socket.assigns | __changed__: %{}}},
        PageLive.render(%{view.socket.assigns | __changed__: nil}),
        Diff.new_fingerprints(),
        Diff.new_components()
      )

    assert html(client) == html(Client.merge_diff(%{}, elem(fresh, 0)))

    socket = view.socket |> Filament.LiveView.run_pending_effects() |> Utils.clear_changed()
    {%{view | socket: socket, prints: prints, components: components, client: client}, diff}
  end

  defp set(view, changes) do
    {:noreply, socket} = PageLive.handle_event("set", changes, view.socket)
    %{view | socket: socket}
  end

  defp click(view, pattern) do
    [_, ref] = Regex.run(~r/phx-click="filament:([^"]+)"[^>]*>#{pattern}</, html(view.client))
    {:noreply, socket} = PageLive.handle_event("filament:" <> ref, %{}, view.socket)
    socket = receive_updates(socket)
    %{view | socket: socket}
  end

  defp receive_updates(socket) do
    receive do
      {:filament_set_state, _, _, _, _} = message ->
        {:noreply, socket} = PageLive.handle_info(message, socket)
        receive_updates(socket)
    after
      0 -> socket
    end
  end

  defp html(client), do: client |> Diff.to_iodata() |> IO.iodata_to_binary()
  defp payload(diff), do: Jason.encode!(diff)

  test "an identical update sends nothing" do
    {view, _} = mount(:html)
    {_view, diff} = view |> set(%{query: "a", rows: rows(25)}) |> frame()
    assert diff == %{}
  end

  for mode <- [:html, :unkeyed, :components], n <- [25, 1000] do
    test "changing an input beside #{n} unchanged #{mode} rows sends only the input" do
      {view, _} = mount(unquote(mode), unquote(n))
      {_view, diff} = view |> set(%{query: "ab"}) |> frame()
      refute payload(diff) =~ "row "
      refute payload(diff) =~ "child"
      assert byte_size(payload(diff)) < 100
    end
  end

  test "a child's own state updates under an unchanged parent and survives the parent's updates" do
    {view, _} = mount(:html)
    {view, diff} = view |> click("child") |> frame()
    assert html(view.client) =~ "child</button> 1"
    refute payload(diff) =~ "row "

    {view, _} = view |> set(%{query: "b"}) |> frame()
    assert html(view.client) =~ "child</button> 1"
  end

  test "a changed prop reaches the child without resending its siblings" do
    {view, _} = mount(:html)
    {view, diff} = view |> set(%{text: "u"}) |> frame()
    assert html(view.client) =~ "<em>u</em>"
    refute payload(diff) =~ "row "
  end

  test "moving the last keyed row to the front keeps its state and resends no row content" do
    {view, _} = mount(:components, 5)
    {view, _} = view |> click("row 5") |> frame()
    moved = [List.last(rows(5)) | Enum.drop(rows(5), -1)]
    {view, diff} = view |> set(%{rows: moved}) |> frame()

    refute payload(diff) =~ "row "
    assert html(view.client) =~ ~r/<ul><li><button[^>]*>row 5<\/button> 1<\/li><li><button[^>]*>row 1<\/button> 0/
  end

  test "moving a keyed HTML row resends no row content" do
    {view, _} = mount(:html, 5)
    {_view, diff} = view |> set(%{rows: [List.last(rows(5)) | Enum.drop(rows(5), -1)]}) |> frame()
    refute payload(diff) =~ "row "
  end

  test "appending, removing and reinserting rows patches the client and cleans up once" do
    for mode <- [:html, :unkeyed, :components] do
      {view, _} = mount(mode, 3)
      {view, diff} = view |> set(%{rows: rows(4)}) |> frame()
      assert payload(diff) =~ "row 4"
      refute payload(diff) =~ "row 1"

      {view, _} = view |> set(%{rows: tl(rows(4))}) |> frame()
      {_view, _} = view |> set(%{rows: rows(4)}) |> frame()
    end

    assert_received {:row_cleanup, "row 1"}
    refute_received {:row_cleanup, "row 1"}
    refute_received {:row_cleanup, _}
  end

  test "switching branches sends the new branch, then tracks it" do
    {view, _} = mount(:html)
    {view, diff} = view |> set(%{flag: false}) |> frame()
    assert payload(diff) =~ "off"
    {view, _} = view |> set(%{flag: true}) |> frame()
    {_view, diff} = view |> set(%{query: "z"}) |> frame()
    refute payload(diff) =~ "row "
  end

  test "switching loop kinds replaces the rows, then tracks them" do
    {view, _} = mount(:html)
    {view, _} = view |> set(%{mode: :components}) |> frame()
    {view, _} = view |> set(%{mode: :unkeyed}) |> frame()
    {_view, diff} = view |> set(%{query: "z"}) |> frame()
    refute payload(diff) =~ "row "
  end

  test "a handler sees a changed captured prop although the markup is unchanged" do
    {view, _} = mount(:html)
    {view, diff} = view |> set(%{secret: 2}) |> frame()
    assert diff == %{}
    click(view, "go")
    assert_received {:go, 2}
  end

  test "several updates before one frame are sent relative to the last frame" do
    {view, _} = mount(:html)
    {view, diff} = view |> set(%{query: "b"}) |> set(%{query: "a"}) |> frame()
    assert diff == %{}

    {_view, diff} = view |> set(%{query: "b"}) |> set(%{query: "b", text: "t"}) |> frame()
    assert payload(diff) =~ ~s("b")
  end

  test "a LiveComponent sends only what changed" do
    {:ok, socket} =
      Filament.LiveComponent.mount(%Socket{
        assigns: %{__changed__: %{}},
        private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
      })

    props = %{
      id: "c",
      component: Page,
      query: "a",
      secret: 1,
      flag: true,
      text: "t",
      mode: :html,
      rows: rows(25),
      test: self()
    }

    {:ok, socket} = Filament.LiveComponent.update(props, socket)

    {_, prints, components} =
      Diff.render(socket, Filament.LiveComponent.render(socket.assigns), Diff.new_fingerprints(), Diff.new_components())

    {:ok, socket} = Filament.LiveComponent.update(%{props | query: "b"}, Utils.clear_changed(socket))
    {diff, _, _} = Diff.render(socket, Filament.LiveComponent.render(socket.assigns), prints, components)
    assert byte_size(payload(diff)) < 100
    refute payload(diff) =~ "row "
  end

  test "loops render the same HTML for the portable target" do
    props = %{query: "a", secret: 1, flag: true, text: "t", rows: rows(3), test: self()}

    for mode <- [:html, :unkeyed, :components] do
      {tree, web, _} = Filament.Reconciler.mount(Page, Map.put(props, :mode, mode), target: Filament.Web)
      {tree2, vnode, _} = Filament.Reconciler.mount(Page, Map.put(props, :mode, mode))

      assert web |> Filament.Web.to_iodata() |> IO.iodata_to_binary() ==
               vnode |> Filament.Web.to_iodata() |> IO.iodata_to_binary()

      Filament.Reconciler.unmount(tree)
      Filament.Reconciler.unmount(tree2)
    end
  end
end
