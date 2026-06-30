defmodule TownSquareBeam.Router do
  @moduledoc """
  The HTTP edge. Plug.Router (the one place we use macros — the universally-read
  `get "/path" do ... end` kind, not hidden-module generation). It does three
  things: serve the *unchanged* vanilla widget assets, answer the health check,
  and upgrade `/live` to a WebSocket. The upgrade is one explicit function call.
  """

  use Plug.Router

  # The widget, byte-for-byte the original. The whole point: the client doesn't
  # change when the backend moves to BEAM.
  @public_dir Path.expand("../../public", __DIR__)

  plug(:embed_cors)

  plug(Plug.Static,
    at: "/",
    from: @public_dir,
    only_matching: ~w(townsquare widget tokens page dev hosted lib shared map staging design)
  )

  plug(Plug.Static, at: "/", from: @public_dir)
  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    send_resp(conn, 200, "ok")
  end

  get "/live" do
    conn = fetch_query_params(conn)
    scene_key = conn.query_params["siteKey"] || "default"
    origin = conn |> get_req_header("origin") |> List.first()

    cond do
      not origin_allowed?(origin) ->
        conn |> send_resp(403, "origin not allowed") |> halt()

      TownSquareBeam.RateLimit.take(client_ip(conn)) == :rate_limited ->
        conn |> send_resp(429, "too many connections") |> halt()

      true ->
        conn
        |> WebSockAdapter.upgrade(
          TownSquareBeam.Socket,
          [scene_key: scene_key, origin: origin],
          timeout: 60_000
        )
        |> halt()
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Embeddable assets must load from other origins, like the Node server's
  # cross-origin headers on /townsquare.mjs and /widget.css.
  defp embed_cors(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "access-control-allow-origin", "*")
  end

  # A `/live` socket may only be opened from an allowlisted origin. The static
  # widget assets stay open (above) — they are meant to embed — but the live
  # connection is locked to the site(s) this server is for.
  defp origin_allowed?(origin) do
    allowed?(origin, Application.get_env(:town_square_beam, :allowed_origins, []))
  end

  @doc """
  The pure allowlist decision. An empty allowlist (the dev default) permits any
  origin; otherwise the request's `Origin` must match exactly. Public so it can
  be tested without standing up a real WebSocket upgrade.
  """
  def allowed?(_origin, []), do: true
  def allowed?(origin, allowed) when is_list(allowed), do: origin in allowed

  # The client IP used as the rate-limit key. By default this is the socket peer
  # (`conn.remote_ip`). Behind a trusted reverse proxy set TOWNSQUARE_TRUST_PROXY
  # so the first hop of `x-forwarded-for` (the real client) is used instead —
  # only enable it when a proxy you control actually sets that header, since it
  # is otherwise attacker-spoofable.
  defp client_ip(conn) do
    if Application.get_env(:town_square_beam, :trust_proxy, false) do
      case get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] when is_binary(forwarded) ->
          forwarded |> String.split(",") |> List.first() |> String.trim()

        _ ->
          peer_ip(conn)
      end
    else
      peer_ip(conn)
    end
  end

  defp peer_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
