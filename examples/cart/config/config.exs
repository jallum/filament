import Config

# Basic Phoenix configuration for the Cart example
config :cart, CartWeb.Router,
  http: [ip: {127, 0, 0, 1}, port: 4001]

config :phoenix, :json_library, Jason

# Enable dev debug output
config :logger, level: :warning
