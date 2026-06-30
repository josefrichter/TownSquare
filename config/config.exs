import Config

# Default HTTP/WebSocket port. The PORT env var overrides this at runtime.
config :town_square_beam, port: 8788

import_config "#{config_env()}.exs"
