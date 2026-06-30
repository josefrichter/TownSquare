defmodule TownSquareBeam.RouterOriginTest do
  # async: false — the integration tests mutate the global :allowed_origins env.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias TownSquareBeam.Router

  @opts Router.init([])

  setup do
    prev = Application.get_env(:town_square_beam, :allowed_origins, [])
    on_exit(fn -> Application.put_env(:town_square_beam, :allowed_origins, prev) end)
    :ok
  end

  defp live(origin) do
    conn = conn(:get, "/live?siteKey=default")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    Router.call(conn, @opts)
  end

  describe "the /live upgrade (integration)" do
    test "rejects an origin not on the allowlist with 403" do
      Application.put_env(:town_square_beam, :allowed_origins, ["https://example.com"])
      assert live("https://attacker.example").status == 403
    end

    test "rejects a missing Origin header when an allowlist is set" do
      Application.put_env(:town_square_beam, :allowed_origins, ["https://example.com"])
      assert live(nil).status == 403
    end
  end

  # The pure decision — exercising the accept path directly, since a real
  # WebSocket upgrade can't be driven through the Plug.Test adapter.
  describe "allowed?/2" do
    test "an empty allowlist permits any origin (dev default)" do
      assert Router.allowed?("https://anything.example", [])
      assert Router.allowed?(nil, [])
    end

    test "a non-empty allowlist requires an exact match" do
      allowed = ["https://example.com", "https://www.example.com"]
      assert Router.allowed?("https://example.com", allowed)
      assert Router.allowed?("https://www.example.com", allowed)
      refute Router.allowed?("https://attacker.example", allowed)
      refute Router.allowed?(nil, allowed)
    end
  end
end
