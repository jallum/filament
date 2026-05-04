import Config

config :phoenix, :json_library, JSON

config :inventory, InventoryWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: InventoryWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Inventory.PubSub,
  live_view: [signing_salt: "inventoryexamplesalt"],
  secret_key_base: "inventory_example_secret_key_base_min_64_chars_xxxxxxxxxxxxxxxxxx",
  code_reloader: true,
  reloadable_apps: [:inventory, :filament]

config :inventory, :dev_routes, true
