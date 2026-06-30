import Config

# Default HTTP/WebSocket port. The PORT env var overrides this at runtime.
config :town_square_beam, port: 8788

# Origins allowed to open a `/live` WebSocket. Empty = allow any (dev default);
# set TOWNSQUARE_ALLOWED_ORIGINS in production to lock the socket to one site.
config :town_square_beam, allowed_origins: []

# Per-IP cap on new `/live` connections: at most `max_conns_per_ip` within each
# `conn_window_ms` window. 0 disables the check. `trust_proxy` decides whether
# the client IP is read from x-forwarded-for (only behind a proxy you control).
config :town_square_beam,
  max_conns_per_ip: 30,
  conn_window_ms: 10_000,
  trust_proxy: false

import_config "#{config_env()}.exs"
