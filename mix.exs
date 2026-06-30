defmodule TownSquareBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :town_square_beam,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {TownSquareBeam.Application, []}
    ]
  end

  # The whole stack: an HTTP/WebSocket server (Bandit), the Plug router
  # contract, the WebSock upgrade glue, and a JSON codec. No web framework, no
  # presence library, no pubsub library — those parts are OTP stdlib here.
  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
