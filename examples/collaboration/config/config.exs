import Config

config :collaboration, CollaborationWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: String.to_integer(System.get_env("PORT") || "4000")],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CollaborationWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Collaboration.PubSub,
  live_view: [signing_salt: "collaborationexamplesalt"],
  secret_key_base: "collaboration_example_secret_key_base_min_64_chars_xxxxxxxxxxxxxxxxxx",
  code_reloader: true,
  reloadable_apps: [:collaboration, :filament]

config :collaboration, :dev_routes, true

config :phoenix, :json_library, JSON
