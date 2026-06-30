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
  require Logger

  @impl true
  def start(_type, _args) do
    # Port (and the origin allowlist) come from config — the compiled default in
    # config.exs, overridden at boot by config/runtime.exs from the environment.
    port = Application.get_env(:town_square_beam, :port, 8788)

    children = [
      {Registry, keys: :unique, name: TownSquareBeam.SceneRegistry},
      {DynamicSupervisor, name: TownSquareBeam.SceneSupervisor, strategy: :one_for_one},
      {Bandit, plug: TownSquareBeam.Router, port: port}
    ]

    opts = [strategy: :one_for_one, name: TownSquareBeam.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info(
          "TownSquareBeam listening on http://127.0.0.1:#{port} " <>
            "(health /healthz · widget /dev/dev.html · socket ws://…/live?siteKey=…)"
        )

        {:ok, pid}

      other ->
        other
    end
  end
end
