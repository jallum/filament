defmodule CartWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :cart

  @session_options [
    store: :cookie,
    key: "_cart_key",
    signing_salt: "cartexamplesalt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false
  )

  plug(Plug.Static,
    at: "/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false
  )

  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.Session, @session_options)
  plug(CartWeb.Router)
end
