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

    conn
    |> WebSockAdapter.upgrade(
      TownSquareBeam.Socket,
      [scene_key: scene_key, origin: origin],
      timeout: 60_000
    )
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Embeddable assets must load from other origins, like the Node server's
  # cross-origin headers on /townsquare.mjs and /widget.css.
  defp embed_cors(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "access-control-allow-origin", "*")
  end
end
