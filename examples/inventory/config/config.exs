import Config

# Basic Phoenix configuration for the Inventory example
config :inventory, InventoryWeb.Router,
  http: [ip: {127, 0, 0, 1}, port: 4002]

config :phoenix, :json_library, Jason

# Enable dev debug output
config :logger, level: :warning
