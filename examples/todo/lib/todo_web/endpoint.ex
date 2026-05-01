defmodule TodoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :todo

  @session_options [
    store: :cookie,
    key: "_todo_key",
    signing_salt: "todoexamplesalt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug TodoWeb.Router
end
