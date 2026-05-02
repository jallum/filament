import Config

config :inventory, InventoryWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4002],
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Inventory.PubSub,
  live_view: [signing_salt: "inventoryexamplesalt"],
  secret_key_base: "inventory_example_secret_key_base_min_64_chars_xxxxxxxxxxxxxxxxxx",
  render_errors: [formats: [html: InventoryWeb.ErrorHTML], layout: false]

config :phoenix, :json_library, JSON

config :logger, level: :warning
