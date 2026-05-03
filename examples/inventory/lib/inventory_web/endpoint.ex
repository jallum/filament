defmodule InventoryWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :inventory

  @session_options [
    store: :cookie,
    key: "_inventory_key",
    signing_salt: "inventoryexamplesalt",
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

  plug(Plug.Session, @session_options)
  plug(InventoryWeb.Router)
end
