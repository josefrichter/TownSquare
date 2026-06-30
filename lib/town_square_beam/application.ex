defmodule TownSquareBeam.Application do
  @moduledoc """
  The supervision tree. This is the crash-isolation story in one place:

    * `SceneRegistry` / `SceneSupervisor` — scenes are started on demand, one
      process each. A scene that crashes is restarted; it does not take down the
      server, other scenes, or any connection.
    * `Bandit` — the HTTP/WebSocket server. Each connection runs in its own
      process supervised by Bandit, so one bad frame closes one socket.

  There is no `try/catch` wrapping the whole world here (the Node server's top
  tech-debt item) because isolation is the default, not something you add.
  """

  use Application

  @impl true
  def start(_type, _args) do
    port =
      case System.get_env("PORT") do
        nil -> Application.get_env(:town_square_beam, :port, 8788)
        value -> String.to_integer(value)
      end

    children = [
      {Registry, keys: :unique, name: TownSquareBeam.SceneRegistry},
      {DynamicSupervisor, name: TownSquareBeam.SceneSupervisor, strategy: :one_for_one},
      {Bandit, plug: TownSquareBeam.Router, port: port}
    ]

    opts = [strategy: :one_for_one, name: TownSquareBeam.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        IO.puts("")
        IO.puts("  TownSquareBeam listening on http://127.0.0.1:#{port}")
        IO.puts("  · health:  http://127.0.0.1:#{port}/healthz")
        IO.puts("  · widget:  http://127.0.0.1:#{port}/dev/dev.html")
        IO.puts("  · socket:  ws://127.0.0.1:#{port}/live?siteKey=…")
        IO.puts("")
        {:ok, pid}

      other ->
        other
    end
  end
end
