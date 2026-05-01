defmodule Filament.TestEndpoint do
  @moduledoc """
  Minimal Phoenix endpoint for testing Filament.LiveView integration
  """
  use Phoenix.Endpoint, otp_app: :filament

  plug Plug.Session,
    store: :cookie,
    key: "_filament_test",
    signing_salt: "test_salt"
  plug Phoenix.LiveView.Flash
  plug Filament.TestRouter
end
