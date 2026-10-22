defmodule Filament.NavigationTest do
  # The endpoint is named, so these tests share it.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  defmodule Pager do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:page, :integer, default: 1)
      prop(:own, :boolean, default: false)
      prop(:base, :string, default: "/")

      def render(%{page: page, own: own, base: base}) do
        navigate = use_navigate()
        next = fn -> navigate.(patch: "#{base}?page=#{page + 1}") end
        same = fn -> navigate.(patch: "#{base}?page=#{page}", replace: true) end
        away = fn -> navigate.(navigate: "/other") end
        out = fn -> navigate.(href: "https://example.com/") end

        ~F"""
        <div>
          <p id="state">page {page} own {inspect(own)}</p>
          <button id="next" on_click={next}>next</button>
          <button id="same" on_click={same}>same</button>
          <button id="away" on_click={away}>away</button>
          <button id="out" on_click={out}>out</button>
        </div>
        """
      end
    end
  end

  defmodule PagerLive do
    @moduledoc false
    use Filament.LiveView

    def root_component, do: Pager

    def handle_params(params, _uri, socket) do
      page = String.to_integer(params["page"] || "1")
      own = Filament.LiveView.own_patch?(socket)
      {:noreply, Filament.LiveView.put_props(socket, page: page, own: own)}
    end
  end

  # A LiveView of its own, with a Filament LiveComponent in it.
  defmodule HostLive do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, _session, socket), do: {:ok, socket}

    def handle_params(params, _uri, socket) do
      page = String.to_integer(params["page"] || "1")
      own = Filament.LiveView.own_patch?(socket)
      {:noreply, Phoenix.Component.assign(socket, page: page, own: own)}
    end

    def handle_info({:filament_navigate, opts}, socket), do: {:noreply, Filament.LiveView.navigate(socket, opts)}

    def render(assigns) do
      ~H"""
      <.live_component module={Filament.LiveComponent} id="pager" component={Pager} page={@page} own={@own} base="/host" />
      """
    end
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
      Router.live("/", PagerLive)
      Router.live("/host", HostLive)
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :filament

    @session [store: :cookie, key: "_nav", signing_salt: "navigation"]
    socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])
    plug(Plug.Session, @session)
    plug(Router)
  end

  @endpoint Endpoint

  setup_all do
    Application.put_env(:filament, Endpoint,
      secret_key_base: String.duplicate("navigation", 8),
      live_view: [signing_salt: "navigation"]
    )

    start_supervised!(Endpoint)
    :ok
  end

  setup do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "page 1 own false"
    %{view: view}
  end

  test "patch: changes the URL, the view kept, and handle_params hears it as the page's own",
       %{view: view} do
    view |> element("#next") |> render_click()
    assert_patch(view, "/?page=2")
    assert render(view) =~ "page 2 own true"
  end

  test "a patch from the browser after the page's own isn't its own", %{view: view} do
    view |> element("#next") |> render_click()
    assert_patch(view, "/?page=2")

    assert render_patch(view, "/?page=5") =~ "page 5 own false"

    view |> element("#next") |> render_click()
    assert_patch(view, "/?page=6")
    assert render(view) =~ "page 6 own true"
  end

  test "replace: patches in place", %{view: view} do
    view |> element("#same") |> render_click()
    assert_patch(view, "/?page=1")
    assert render(view) =~ "page 1 own true"
  end

  test "navigate: goes to another LiveView", %{view: view} do
    view |> element("#away") |> render_click()
    assert_redirect(view, "/other")
  end

  test "a LiveComponent's host applies its navigations with navigate/2" do
    {:ok, view, html} = live(build_conn(), "/host")
    assert html =~ "page 1 own false"

    view |> element("#next") |> render_click()
    assert_patch(view, "/host?page=2")
    assert render(view) =~ "page 2 own true"

    assert render_patch(view, "/host?page=7") =~ "page 7 own false"
  end

  test "href: loads another page", %{view: view} do
    view |> element("#out") |> render_click()
    assert_redirect(view, "https://example.com/")
  end
end
