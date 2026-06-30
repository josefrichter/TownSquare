import Config

# Runtime configuration — evaluated when the app boots, for both `mix`/`iex -S mix`
# and a built release. One artifact, configured entirely by the environment.

# PORT overrides the compiled default (config.exs) in every environment.
if port = System.get_env("PORT") do
  config :town_square_beam, port: String.to_integer(port)
end

# TOWNSQUARE_ALLOWED_ORIGINS is a comma-separated allowlist of origins permitted
# to open a `/live` WebSocket, e.g. "https://example.com,https://www.example.com".
# Leave it unset in dev to allow any origin; set it in production to lock the
# socket to the one site this server is for.
config :town_square_beam,
  allowed_origins:
    System.get_env("TOWNSQUARE_ALLOWED_ORIGINS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

# Per-IP connection budget. TOWNSQUARE_MAX_CONNECTIONS_PER_IP overrides the cap
# (0 disables it); TOWNSQUARE_TRUST_PROXY=true reads the client IP from
# x-forwarded-for when the server sits behind a reverse proxy you control.
if max = System.get_env("TOWNSQUARE_MAX_CONNECTIONS_PER_IP") do
  config :town_square_beam, max_conns_per_ip: String.to_integer(max)
end

config :town_square_beam,
  trust_proxy: System.get_env("TOWNSQUARE_TRUST_PROXY") == "true"
