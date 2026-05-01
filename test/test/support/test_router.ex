defmodule Filament.TestRouter do
  @moduledoc """
  Minimal Phoenix router for testing Filament.LiveView integration
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router

  # For basic test routing
  get "/", Phoenix.LiveView.Controller, :home

  # Counter test live view
  live "/counter", Filament.Test.CounterLiveView
end
