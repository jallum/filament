defmodule Filament.HeadLiveTest do
  # The endpoint is named, so these tests share it.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  defmodule Product do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:name, :string, default: "boots")

      def render(%{name: name}) do
        {name, set_name} = use_state(name)
        rename = fn -> set_name.("hats") end
        use_head(title: "#{name} · Shop", canonical: "https://shop.test/#{name}", meta: [description: name])

        ~F"""
        <div>
          <button id="rename" on_click={rename}>rename</button>
          <a id="about" navigate="/about">about</a>
        </div>
        """
      end
    end
  end

  defmodule About do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props), do: ~F"<p>about</p>"
    end
  end

  defmodule ProductLive do
    @moduledoc false
    use Filament.LiveView

    def root_component, do: Product
  end

  defmodule AboutLive do
    @moduledoc false
    use Filament.LiveView

    def root_component, do: About
  end

  # A view that names its own title.
  defmodule TitledLive do
    @moduledoc false
    use Filament.LiveView

    def root_component, do: Product

    def mount(params, session, socket),
      do: super(params, session, Phoenix.Component.assign(socket, :page_title, "Mine"))
  end

  defmodule Layouts do
    @moduledoc false
    use Phoenix.Component

    def root(assigns) do
      ~H"""
      <html>
        <head>
          <.live_title default="Shop">{assigns[:page_title]}</.live_title>
          <meta name="viewport" content="width=device-width" />
          <Filament.LiveView.head_tags head={assigns[:filament_head]} />
        </head>
        <body>{@inner_content}</body>
      </html>
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
      plug(:put_root_layout, html: {Layouts, :root})
    end

    scope "/" do
      pipe_through(:browser)

      Router.live_session :default do
        Router.live("/", ProductLive)
        Router.live("/about", AboutLive)
        Router.live("/titled", TitledLive)
      end
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Phoenix.Endpoint, otp_app: :filament

    @session [store: :cookie, key: "_head", signing_salt: "head"]
    socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])
    plug(Plug.Session, @session)
    plug(Router)
  end

  @endpoint Endpoint

  setup_all do
    Application.put_env(:filament, Endpoint,
      secret_key_base: String.duplicate("filament-head", 8),
      live_view: [signing_salt: "filament-head"]
    )

    start_supervised!(Endpoint)
    :ok
  end

  test "the first page load's root layout renders the head" do
    html = build_conn() |> get("/") |> html_response(200)

    assert html =~ ~s(<title data-default="Shop">boots · Shop</title>)
    assert html =~ ~s(<link rel="canonical" href="https://shop.test/boots" data-filament-head>)
    assert html =~ ~s(<meta name="description" content="boots" data-filament-head>)
    assert html =~ ~s(<meta name="viewport" content="width=device-width">)
  end

  test "the connected view pushes its tags and keeps its title as they change" do
    {:ok, view, _html} = live(build_conn(), "/")
    assert page_title(view) == "boots · Shop"

    assert_push_event(view, "filament:head", %{
      tags: [
        %{"tag" => "link", "rel" => "canonical", "href" => "https://shop.test/boots"},
        %{"tag" => "meta", "name" => "description", "content" => "boots"}
      ]
    })

    # The setter's render follows the click's reply; render/1 waits for it.
    view |> element("#rename") |> render_click()
    render(view)
    assert page_title(view) == "hats · Shop"
    assert_push_event(view, "filament:head", %{tags: [%{"href" => "https://shop.test/hats"}, %{"content" => "hats"}]})
  end

  test "a page navigated to live replaces the last one's head" do
    {:ok, view, _html} = live(build_conn(), "/")
    assert_push_event(view, "filament:head", _)

    {:ok, about, _html} = view |> element("#about") |> render_click() |> follow_redirect(build_conn())
    assert page_title(about) == "Shop"
    assert_push_event(about, "filament:head", %{tags: []})
  end

  test "a view that assigns page_title keeps it" do
    {:ok, view, html} = live(build_conn(), "/titled")
    assert html =~ "Mine"
    assert page_title(view) == "Mine"

    view |> element("#rename") |> render_click()
    render(view)
    assert page_title(view) == "Mine"
  end
end
