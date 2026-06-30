import Config

# Bind to an ephemeral port in tests so the suite never collides with a
# running dev server.
config :town_square_beam, port: 0
