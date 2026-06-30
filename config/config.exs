import Config

# Default HTTP/WebSocket port. The PORT env var overrides this at runtime.
config :town_square_beam, port: 8788

# Origins allowed to open a `/live` WebSocket. Empty = allow any (dev default);
# set TOWNSQUARE_ALLOWED_ORIGINS in production to lock the socket to one site.
config :town_square_beam, allowed_origins: []

import_config "#{config_env()}.exs"
