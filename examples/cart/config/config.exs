import Config

config :cart, CartWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4001],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Cart.PubSub,
  live_view: [signing_salt: "cartexamplesalt"],
  secret_key_base: "cart_example_secret_key_base_min_64_chars_xxxxxxxxxxxxxxxxxxxxxxxxxxx",
  render_errors: [formats: [html: CartWeb.ErrorHTML], layout: false],
  code_reloader: true,
  reloadable_apps: [:cart, :filament],
  watchers: []

# Enable dev debug output
config :logger, level: :warning

config :phoenix, :json_library, JSON
