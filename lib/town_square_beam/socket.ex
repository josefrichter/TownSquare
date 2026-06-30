defmodule TownSquareBeam.Socket do
  @moduledoc """
  One WebSocket connection. A plain `WebSock` behaviour module — four callbacks,
  no macros, nothing generated behind your back. This is the direct analog of
  the Node `ws` connection handler.

  The callbacks map 1:1 to the old server's events:

      init/1        ~ "connection"   (we wait for the client's `init` frame to join)
      handle_in/2   ~ "message"
      handle_info/2 ~ a scene broadcast destined for this client
      terminate/2   ~ "close"        (cleanup is the scene's job, via monitor)

  Per-connection throttles live here, exactly where server.js keeps them (on the
  `client` object). Content rules (text cap, seat arbitration) live in the scene.
  """

  @behaviour WebSock

  alias TownSquareBeam.Scene

  @move_throttle_ms 40
  @action_throttle_ms 560
  @chat_throttle_ms 500

  # Runs once per WebSocket, in this connection's own process. `Scene.ensure/1` is
  # server.js's getScene() get-or-create — but it returns a live process (pid), not
  # an object pulled from a `scenes` Map. The last_*_at fields are the per-connection
  # throttle clocks server.js stored on the `client` object; they live here because
  # throttling is per-tab, not per-visitor. Note: connecting does NOT join yet —
  # identity_id stays nil until the client sends an `init` frame.
  @impl true
  def init(opts) do
    state = %{
      conn_id: :erlang.unique_integer([:positive]),
      scene: Scene.ensure(opts[:scene_key]),
      origin: opts[:origin],
      identity_id: nil,
      last_move_at: nil,
      last_action_at: nil,
      last_chat_at: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => type} = msg} -> dispatch(type, msg, state)
      _ -> {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  # The scene fan-out lands here: Scene.broadcast does `send(pid, {:ws_push, ...})`
  # to every socket process, and {:push, ...} writes it to this tab's wire. This is
  # the receiving end of server.js's `client.ws.send(payload)` loop.
  @impl true
  def handle_info({:ws_push, payload}, state), do: {:push, {:text, payload}, state}
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # --- dispatch -------------------------------------------------------------

  # Join only happens via `init`; everything else is ignored until joined.
  defp dispatch("init", _msg, %{identity_id: id} = state) when not is_nil(id), do: {:ok, state}

  defp dispatch("init", msg, state) do
    params = %{
      conn_id: state.conn_id,
      origin: state.origin,
      browser_id: Map.get(msg, "browserId"),
      browser_secret: Map.get(msg, "browserSecret"),
      x: Map.get(msg, "x"),
      display_name: Map.get(msg, "displayName"),
      color: Map.get(msg, "color"),
      reading_active: Map.get(msg, "readingActive")
    }

    params =
      if Map.has_key?(msg, "readingUrl"),
        do: Map.put(params, :reading_url, Map.get(msg, "readingUrl")),
        else: params

    {:ok, hello, id} = Scene.join(state.scene, params)
    {:push, {:text, hello}, %{state | identity_id: id}}
  end

  defp dispatch(_type, _msg, %{identity_id: nil} = state), do: {:ok, state}

  defp dispatch("move", %{"x" => x}, state) do
    throttle(state, :last_move_at, @move_throttle_ms, fn -> Scene.move(state.scene, x) end)
  end

  defp dispatch("say", %{"text" => text}, state) do
    throttle(state, :last_chat_at, @chat_throttle_ms, fn -> Scene.say(state.scene, text) end)
  end

  defp dispatch("typing", %{"typing" => on?}, state) do
    Scene.typing(state.scene, on?)
    {:ok, state}
  end

  defp dispatch("action", %{"action" => name} = msg, state) do
    throttle(state, :last_action_at, @action_throttle_ms, fn ->
      Scene.action(state.scene, name, normalize_target(Map.get(msg, "targetId")))
    end)
  end

  defp dispatch("profile", msg, state) do
    Scene.profile(state.scene, Map.get(msg, "displayName"), Map.get(msg, "color"))
    {:ok, state}
  end

  defp dispatch("reading", msg, state) do
    Scene.reading(state.scene, msg)
    {:ok, state}
  end

  defp dispatch("settle", %{"propId" => prop_id}, state) do
    Scene.settle(state.scene, prop_id)
    {:ok, state}
  end

  defp dispatch(_type, _msg, state), do: {:ok, state}

  # --- helpers --------------------------------------------------------------

  # Per-connection rate limiting, the same idea as server.js gating on the `client`
  # object's last-sent timestamps (move 40ms / chat 500ms / action 560ms). State is
  # local to this process, so one chatty tab can't throttle another.
  defp throttle(state, key, window, fun) do
    now = System.monotonic_time(:millisecond)
    last = Map.fetch!(state, key)

    if last != nil and now - last < window do
      {:ok, state}
    else
      fun.()
      {:ok, Map.put(state, key, now)}
    end
  end

  defp normalize_target(id) when is_integer(id), do: id

  defp normalize_target(id) when is_binary(id),
    do:
      case(Integer.parse(id),
        do: (
          {n, ""} -> n
          _ -> nil
        )
      )

  defp normalize_target(_), do: nil
end
