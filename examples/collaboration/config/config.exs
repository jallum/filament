import Config

config :collaboration, CollaborationWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4003],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Collaboration.PubSub,
  live_view: [signing_salt: "collaborationexamplesalt"],
  secret_key_base: "collaboration_example_secret_key_base_min_64_chars_xxxxxxxxxxxxxxxxxx",
  render_errors: [formats: [html: CollaborationWeb.ErrorHTML], layout: false],
  code_reloader: true,
  reloadable_apps: [:collaboration, :filament],
  watchers: []

config :phoenix, :json_library, JSON

config :logger, level: :warning
