import Config

config :cart, CartWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CartWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Cart.PubSub,
  live_view: [signing_salt: "cartexamplesalt"],
  secret_key_base: "cart_example_secret_key_base_min_64_chars_xxxxxxxxxxxxxxxxxxxxxxxxxxx",
  code_reloader: true,
  reloadable_apps: [:cart, :filament]

config :cart, :dev_routes, true

config :phoenix, :json_library, JSON
