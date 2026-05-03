import Config

config :todo, TodoWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TodoWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Todo.PubSub,
  live_view: [signing_salt: "todoexamplesalt"],
  secret_key_base: "todo_example_secret_key_base_min_64_chars_xxxxxxxxxxxxxxxxxxxxxxxxxxx",
  code_reloader: true,
  reloadable_apps: [:todo, :filament]

config :todo, :dev_routes, true

config :phoenix, :json_library, JSON
