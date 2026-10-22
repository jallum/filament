defmodule Filament.LiveComponentEventsTest do
  # The endpoint is named, so these tests share it.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  defmodule Child do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:label, :string, required: true)

      def render(%{label: label}) do
        {n, set_n} = use_state(0)

        ~F"""
        <button id={"child-#{label}"} on_click={fn -> set_n.(n + 1) end}>{label} child {n}</button>
        """
      end
    end
  end

  defmodule Counter do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:label, :string, required: true)

      def render(%{label: label}) do
        {n, set_n} = use_state(0)

        ~F"""
        <div>
          <span on_key={fn key, _mods -> if key == "+", do: set_n.(n + 1) end} />
          <button id={"inc-#{label}"} on_click={fn -> set_n.(n + 1) end}>{label} {n}</button>
          <Filament.LiveComponentEventsTest.Child label={label} />
        </div>
        """
      end
    end
  end

  # A LiveView of its own, two Filament LiveComponents in it.
  defmodule HostLive do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, _session, socket), do: {:ok, socket}

    def handle_info(msg, socket)
        when elem(msg, 0) in [:filament_set_state, :cell_update, :cell_updates, :cell_resubscribe] do
      for id <- ["a", "b"], do: Phoenix.LiveView.send_update(Filament.LiveComponent, id: id, filament_msg: msg)
      {:noreply, socket}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.live_component module={Filament.LiveComponent} id="a" component={Counter} label="a" />
        <.live_component module={Filament.LiveComponent} id="b" component={Counter} label="b" />
      </div>
      """
    end
  end

  defmodule CounterLive do
    @moduledoc false
    use Filament.LiveView

    def mount(_params, _session, socket), do: super(%{}, %{}, Phoenix.Component.assign(socket, label: "v"))
    def root_component, do: Counter
  end

  defmodule Router do
    @moduledoc false
    use Phoenix.Router

    alias Phoenix.LiveView.Router

    # Qualified: the test's own `live/2` is Phoenix.LiveViewTest's.
    require Router

    pipeline :browser do
      plug(:fetch_session)
    end

    scope "/" do
      pipe_through(:browser)
      Router.live("/host", HostLive)
      Router.live("/view", CounterLive)
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :filament

    @session [store: :cookie, key: "_events", signing_salt: "lc-events"]
    socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])
    plug(Plug.Session, @session)
    plug(Router)
  end

  @endpoint Endpoint

  setup_all do
    Application.put_env(:filament, Endpoint,
      secret_key_base: String.duplicate("lc-events", 8),
      live_view: [signing_salt: "lc-events"]
    )

    start_supervised!(Endpoint)
    :ok
  end

  test "a LiveComponent's events reach it, not the LiveView it's in" do
    {:ok, view, _html} = live(build_conn(), "/host")

    view |> element("#inc-a") |> render_click()
    view |> element("#inc-a") |> render_click()
    html = render(view)
    assert html =~ "a 2"
    assert html =~ "b 0"
  end

  test "a child component's events in a LiveComponent reach it" do
    {:ok, view, _html} = live(build_conn(), "/host")

    view |> element("#child-b") |> render_click()
    html = render(view)
    assert html =~ "b child 1"
    assert html =~ "a child 0"
  end

  # Its hook pushes to its own element, which is inside the component.
  test "a LiveComponent's on_key events reach it" do
    {:ok, view, html} = live(build_conn(), "/host")
    # The first is a's: one id per component, though both trees' refs match.
    [[_, id_a, wire], [_, id_b, wire]] =
      ~r/data-filament-wire="(root:\d+)" id="(\d+:root:\d+)"/
      |> Regex.scan(html)
      |> Enum.map(fn [m, w, id] -> [m, id, w] end)

    assert id_a != id_b

    view |> element(~s([id="#{id_a}"])) |> render_hook("filament:#{wire}", %{"key" => "+"})
    html = render(view)
    assert html =~ "a 1"
    assert html =~ "b 0"
  end

  test "a LiveView's elements have no phx-target" do
    {:ok, view, html} = live(build_conn(), "/view")
    refute html =~ "phx-target"

    view |> element("#inc-v") |> render_click()
    assert render(view) =~ "v 1"
  end
end
