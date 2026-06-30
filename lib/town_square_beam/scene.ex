defmodule TownSquareBeam.Scene do
  @moduledoc """
  One scene = one GenServer. It owns every identity in that scene, arbitrates
  seats, and broadcasts to the connected sockets.

  This single process *is* the presence store and the pubsub for its scene.
  There is no separate presence library and no pubsub library: the identities
  map below is the roster, and `broadcast/3` is the fan-out.

  Disconnect handling is the part worth reading. On join the scene calls
  `Process.monitor/1` on the connection process. When that process exits — tab
  closed, network dropped, crash — the scene receives `:DOWN` and reclaims the
  socket. A connection's exit *is* the leave event; there is no separate
  close callback to wire up and no timer that can outlive the thing it guards.
  """

  use GenServer
  require Logger

  alias TownSquareBeam.{Props, Reading}

  # Ported constants (server.js + shared-constants.mjs).
  @min_x 0.02
  @max_x 0.98
  @message_max 140
  @display_name_max 18
  @max_recent_messages 5
  @high_five_distance 0.07
  @default_chat_throttle_ms 500
  @reconnect_grace_ms 1500
  @character_colors ~w(#5f6b73 #c8641f #3f7f63 #3f6fb5 #8a5fb1 #b44f6f)
  @default_color "#5f6b73"
  @valid_actions ~w(jump raise-hand high-five)

  # --- Public API -----------------------------------------------------------

  @doc "Find the running scene for `key`, starting one under the supervisor if needed."
  def ensure(key) do
    case Registry.lookup(TownSquareBeam.SceneRegistry, key) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
               TownSquareBeam.SceneSupervisor,
               {__MODULE__, key}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  def start_link(key) do
    GenServer.start_link(__MODULE__, key,
      name: {:via, Registry, {TownSquareBeam.SceneRegistry, key}}
    )
  end

  @doc "Join (or rejoin) the scene. Returns the encoded `hello` frame and the identity id."
  def join(scene, params), do: GenServer.call(scene, {:join, params})

  # Each of these is called FROM the socket process, so `self()` is that socket's
  # pid — the scene uses it to find the right identity (via pid_index) and to skip
  # the sender when broadcasting. In server.js the handler already had the `client`
  # object in hand; here the socket passes its pid along as the message's identity.
  def move(scene, x), do: GenServer.cast(scene, {:move, self(), x})
  def say(scene, text), do: GenServer.cast(scene, {:say, self(), text})
  def typing(scene, on?), do: GenServer.cast(scene, {:typing, self(), on?})
  def action(scene, name, target), do: GenServer.cast(scene, {:action, self(), name, target})
  def profile(scene, name, color), do: GenServer.cast(scene, {:profile, self(), name, color})
  def reading(scene, msg), do: GenServer.cast(scene, {:reading, self(), msg})
  def settle(scene, prop_id), do: GenServer.cast(scene, {:settle, self(), prop_id})

  # --- GenServer ------------------------------------------------------------

  # The whole state map is what `createScene()` returned in server.js. Field map:
  #   ids       ~ scene.identities        (identityId => identity; the roster)
  #   by_key    ~ scene.identityByBrowser (browserId   => identityId; dedup index)
  #   next_id   ~ scene.nextIdentityId
  #   pid_index ~ has no JS twin. server.js kept a `scene.clients` Map of connection
  #               OBJECTS; here a "client" is a process, so we just map its pid to the
  #               identity it belongs to. The socket's own state lives in its process.
  @impl true
  def init(key), do: {:ok, %{key: key, ids: %{}, by_key: %{}, next_id: 1, pid_index: %{}}}

  # This is server.js's handleInit() (the `init` branch of handleClientMessage).
  # `{pid, _}` is the caller — i.e. the socket process for this tab. We never see a
  # `client` object the way server.js does; we get the calling process's pid.
  @impl true
  def handle_call({:join, params}, {pid, _}, state) do
    key = identity_key(params.browser_id, params.conn_id)
    {identity, state} = get_or_create_identity(state, key, params)
    # Reconnected inside the grace window? Cancel the pending leave (~ clearLeaveTimer).
    identity = cancel_leave_timer(identity)

    prev = {identity.reading_label, identity.reading_url, identity.reading_active}

    identity =
      if Map.has_key?(params, :reading_url) do
        {label, url} = Reading.sanitize(params.reading_url, params.origin)
        %{identity | reading_label: label, reading_url: url}
      else
        identity
      end

    first_join? = not identity.joined

    identity =
      if first_join? do
        %{
          identity
          | display_name: sanitize_display_name(params.display_name),
            color: sanitize_color(params.color)
        }
      else
        identity
      end

    conn_active = params.reading_active != false

    # identity.sockets is the Elixir twin of server.js's `identity.clients` Set:
    # all the tabs belonging to one visitor. Adding this pid is "another tab of an
    # existing visitor" — no new JOIN is broadcast, exactly like server.js.
    identity =
      identity
      |> put_in([:sockets, pid], %{reading_active: conn_active, typing: false})
      |> Map.put(:joined, true)
      |> refresh_reading_active()

    # server.js wired ws.on("close", () => handleClientClose(client)). Here we
    # monitor the socket process instead: its death (tab closed, crash, network
    # drop) arrives as a :DOWN message below. One line replaces the whole close-
    # handler wiring — and tech-debt H5 (a forgotten close handler leaking sockets)
    # can't happen because there's no handler to forget.
    Process.monitor(pid)
    state = put_in(state.pid_index[pid], identity.id)
    state = put_in(state.ids[identity.id], identity)

    peers =
      state.ids
      |> Map.values()
      |> Enum.filter(&(&1.joined and &1.id != identity.id))
      |> Enum.map(&snapshot/1)

    hello =
      identity
      |> snapshot()
      |> Map.delete(:id)
      |> Map.merge(%{
        type: "hello",
        id: identity.id,
        browserSecret: identity.secret,
        peers: peers,
        birds: [],
        chatThrottleMs: @default_chat_throttle_ms,
        pluginModules: []
      })

    if first_join? do
      broadcast(state, %{type: "join", peer: snapshot(identity)}, except: pid)
    else
      {new_label, new_url, new_active} =
        {identity.reading_label, identity.reading_url, identity.reading_active}

      if {new_label, new_url, new_active} != prev do
        broadcast(state, reading_frame(identity), except: pid)
      end
    end

    {:reply, {:ok, Jason.encode!(hello), identity.id}, state}
  end

  @impl true
  def handle_cast({:move, pid, x}, state) do
    with_identity(state, pid, fn id, st ->
      case clamp(x) do
        nil ->
          st

        nx ->
          identity = %{id | x: nx, pose: nil, prop_id: nil}
          st = put_in(st.ids[identity.id], identity)
          broadcast(st, move_frame(identity), except: pid)
          st
      end
    end)
  end

  def handle_cast({:say, pid, text}, state) do
    with_identity(state, pid, fn id, st ->
      case sanitize_message(text) do
        "" ->
          st

        clean ->
          messages =
            Enum.take(id.messages ++ [%{text: clean, at: now_ms()}], -@max_recent_messages)

          identity = %{id | messages: messages}
          st = put_in(st.ids[identity.id], identity)
          broadcast(st, %{type: "say", id: identity.id, text: clean, at: now_ms()}, except: pid)
          st
      end
    end)
  end

  def handle_cast({:typing, pid, on?}, state) when is_boolean(on?) do
    with_identity(state, pid, fn id, st ->
      was_typing = Enum.any?(id.sockets, fn {_, s} -> s.typing end)
      typing = on? or Enum.any?(id.sockets, fn {p, s} -> p != pid and s.typing end)

      if typing == was_typing do
        st
      else
        identity = put_in(id.sockets[pid].typing, on?)
        st = put_in(st.ids[identity.id], identity)
        broadcast(st, %{type: "typing", id: identity.id, typing: typing})
        st
      end
    end)
  end

  def handle_cast({:typing, _pid, _}, state), do: {:noreply, state}

  def handle_cast({:action, pid, name, target_id}, state) when name in @valid_actions do
    with_identity(state, pid, fn id, st ->
      target = if name == "high-five", do: Map.get(st.ids, target_id), else: nil

      cond do
        name == "high-five" and not valid_high_five?(id, target) ->
          st

        true ->
          identity = %{id | pose: nil, prop_id: nil}
          st = put_in(st.ids[identity.id], identity)
          frame = %{type: "action", id: identity.id, action: name}
          frame = if name == "high-five", do: Map.put(frame, :targetId, target_id), else: frame
          broadcast(st, frame, except: pid)
          st
      end
    end)
  end

  def handle_cast({:action, _pid, _name, _target}, state), do: {:noreply, state}

  def handle_cast({:profile, pid, name, color}, state) do
    with_identity(state, pid, fn id, st ->
      display_name = sanitize_display_name(name)
      color = sanitize_color(color)

      if display_name == id.display_name and color == id.color do
        st
      else
        identity = %{id | display_name: display_name, color: color}
        st = put_in(st.ids[identity.id], identity)
        broadcast(st, profile_frame(identity))
        st
      end
    end)
  end

  def handle_cast({:reading, pid, msg}, state) do
    with_identity(state, pid, fn id, st ->
      {label, url} = Reading.sanitize(Map.get(msg, "readingUrl", id.reading_url), id.origin)
      incoming_active = Map.get(msg, "readingActive") != false
      conn_prev_active = id.sockets[pid].reading_active
      prev = {id.reading_label, id.reading_url, id.reading_active}

      if {label, url, incoming_active} == {id.reading_label, id.reading_url, conn_prev_active} do
        st
      else
        identity =
          id
          |> put_in([:sockets, pid, :reading_active], incoming_active)
          |> Map.merge(%{reading_label: label, reading_url: url})
          |> refresh_reading_active()

        st = put_in(st.ids[identity.id], identity)

        if {identity.reading_label, identity.reading_url, identity.reading_active} == prev do
          st
        else
          broadcast(st, reading_frame(identity))
          st
        end
      end
    end)
  end

  def handle_cast({:settle, pid, prop_id}, state) do
    with_identity(state, pid, fn id, st ->
      prop = Props.get(prop_id)

      cond do
        is_nil(prop) ->
          st

        not Props.within_settle_zone?(prop, id.x) ->
          st

        true ->
          case free_seat_x(st, prop, id.x, id.id) do
            nil ->
              st

            seat_x ->
              identity = %{id | x: seat_x, pose: prop.pose, prop_id: prop.id}
              st = put_in(st.ids[identity.id], identity)
              broadcast(st, move_frame(identity))
              st
          end
      end
    end)
  end

  # The monitor we set up in :join fires here. This is server.js's
  # handleClientClose() — except it covers tab-close, crash, AND network-drop with
  # one clause, because they're all just "the process exited". Reclaim its socket; if
  # the identity has no sockets left, start the reconnect-grace countdown.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.pid_index, pid) do
      {nil, _} ->
        {:noreply, state}

      {id, pid_index} ->
        state = %{state | pid_index: pid_index}
        identity = Map.get(state.ids, id)
        drop_socket(state, identity, pid)
    end
  end

  # Fired by the grace timer below; this is server.js's finalizeDisconnect(). Note
  # what's NOT here: server.js had to re-check `scenes.get(scene.key) !== scene` to
  # avoid acting on a torn-down scene (tech-debt H7). We don't, because the timer
  # lives inside THIS process — if the scene had exited, this message was never delivered.
  def handle_info({:finalize, id}, state) do
    case Map.get(state.ids, id) do
      # Still no sockets after the grace window → really gone. (A reconnect would
      # have re-added a socket and cancelled this timer.)
      %{sockets: sockets} = identity when map_size(sockets) == 0 ->
        state = %{
          state
          | ids: Map.delete(state.ids, id),
            by_key: Map.delete(state.by_key, identity.key)
        }

        if identity.joined, do: broadcast(state, %{type: "leave", id: id})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ------------------------------------------------------------

  defp drop_socket(state, identity, pid) do
    was_typing = Enum.any?(identity.sockets, fn {_, s} -> s.typing end)
    identity = update_in(identity.sockets, &Map.delete(&1, pid))

    if was_typing and not Enum.any?(identity.sockets, fn {_, s} -> s.typing end) do
      broadcast(state, %{type: "typing", id: identity.id, typing: false})
    end

    cond do
      map_size(identity.sockets) > 0 ->
        before = state.ids[identity.id].reading_active
        identity = refresh_reading_active(identity)
        state = put_in(state.ids[identity.id], identity)
        if identity.reading_active != before, do: broadcast(state, reading_frame(identity))
        {:noreply, state}

      # Last tab gone. server.js did `identity.leaveTimer = setTimeout(...)` with a
      # GLOBAL timer that could outlive its scene (tech-debt H7). Here the timer is
      # scoped to this process: send_after(self(), ...) means if the scene process
      # exits, this timer is dropped with it, by construction.
      true ->
        timer = Process.send_after(self(), {:finalize, identity.id}, @reconnect_grace_ms)
        identity = %{identity | leave_timer: timer}
        {:noreply, put_in(state.ids[identity.id], identity)}
    end
  end

  # server.js's getOrCreateIdentity(). The browserId groups a person's tabs into one
  # identity; the server-issued secret is the anti-spoof check (a copied browserId
  # without the matching secret can't hijack the real visitor).
  defp get_or_create_identity(state, key, params) do
    case Map.get(state.by_key, key) do
      nil ->
        create_identity(state, key, params)

      id ->
        existing = state.ids[id]
        secret = clean_secret(params.browser_secret)

        if secret != "" and secret == existing.secret do
          # Same browserId + matching secret = same person, another tab → reuse.
          {existing, state}
        else
          # Stolen / secret-less browserId: fork a fresh ephemeral identity keyed
          # to this connection, so it can't hijack the real visitor.
          create_identity(state, "connection-#{params.conn_id}", params)
        end
    end
  end

  defp create_identity(state, key, params) do
    id = state.next_id

    identity = %{
      id: id,
      key: key,
      secret: gen_secret(),
      x: clamp(params.x) || random_spawn_x(),
      pose: nil,
      prop_id: nil,
      display_name: "",
      color: @default_color,
      reading_label: "",
      reading_url: "",
      reading_active: true,
      origin: params.origin,
      joined: false,
      messages: [],
      sockets: %{},
      leave_timer: nil
    }

    state = %{
      state
      | next_id: id + 1,
        by_key: Map.put(state.by_key, key, id),
        ids: Map.put(state.ids, id, identity)
    }

    {identity, state}
  end

  defp with_identity(state, pid, fun) do
    case Map.get(state.pid_index, pid) do
      nil -> {:noreply, state}
      id -> {:noreply, fun.(state.ids[id], state)}
    end
  end

  defp cancel_leave_timer(%{leave_timer: nil} = identity), do: identity

  defp cancel_leave_timer(%{leave_timer: timer} = identity) do
    Process.cancel_timer(timer)
    %{identity | leave_timer: nil}
  end

  defp refresh_reading_active(identity) do
    active = Enum.any?(identity.sockets, fn {_, s} -> s.reading_active end)
    %{identity | reading_active: active}
  end

  defp valid_high_five?(_self, nil), do: false

  defp valid_high_five?(self_id, target) do
    target.joined and target.id != self_id.id and abs(target.x - self_id.x) <= @high_five_distance
  end

  # Mirror findAvailableSeatX: take the nearest free seat to the requested x.
  defp free_seat_x(state, prop, requested_x, exclude_id) do
    seats = prop.seats

    taken =
      for identity <- Map.values(state.ids),
          identity.joined,
          identity.prop_id == prop.id,
          identity.id != exclude_id,
          idx = Enum.find_index(seats, &(abs(identity.x - (prop.x + &1)) < 0.005)),
          idx != nil,
          into: MapSet.new(),
          do: idx

    seats
    |> Enum.with_index()
    |> Enum.reject(fn {_offset, idx} -> MapSet.member?(taken, idx) end)
    |> Enum.map(fn {offset, _idx} -> prop.x + offset end)
    |> case do
      [] -> nil
      free -> Enum.min_by(free, &abs(&1 - requested_x))
    end
  end

  # --- serialization (camelCase wire shape, never leaks browser id/secret) ---

  defp snapshot(i) do
    %{
      id: i.id,
      x: i.x,
      pose: i.pose,
      propId: i.prop_id,
      displayName: i.display_name,
      color: i.color,
      readingLabel: i.reading_label,
      readingUrl: i.reading_url,
      readingActive: i.reading_active,
      isOwner: false,
      messages: i.messages
    }
  end

  defp move_frame(i) do
    %{
      type: "move",
      id: i.id,
      x: i.x,
      pose: i.pose,
      propId: i.prop_id,
      displayName: i.display_name,
      color: i.color,
      readingLabel: i.reading_label,
      readingUrl: i.reading_url,
      readingActive: i.reading_active
    }
  end

  defp profile_frame(i) do
    %{
      type: "profile",
      id: i.id,
      x: i.x,
      pose: i.pose,
      propId: i.prop_id,
      displayName: i.display_name,
      color: i.color,
      isOwner: false
    }
  end

  defp reading_frame(i) do
    %{
      type: "reading",
      id: i.id,
      readingLabel: i.reading_label,
      readingUrl: i.reading_url,
      readingActive: i.reading_active
    }
  end

  # Encode once, fan out to every socket except the optional sender — the exact
  # shape of server.js's `const payload = JSON.stringify(message)` broadcast.
  defp broadcast(state, frame, opts \\ []) do
    except = Keyword.get(opts, :except)
    payload = Jason.encode!(frame)

    for identity <- Map.values(state.ids),
        {pid, _} <- identity.sockets,
        pid != except do
      send(pid, {:ws_push, payload})
    end

    :ok
  end

  # --- small ports ----------------------------------------------------------

  defp identity_key(browser_id, conn_id) do
    case clean_browser_id(browser_id) do
      "" -> "connection-#{conn_id}"
      id -> id
    end
  end

  defp clean_browser_id(id) when is_binary(id), do: id |> String.trim() |> String.slice(0, 100)
  defp clean_browser_id(_), do: ""

  defp clean_secret(s) when is_binary(s), do: String.trim(s)
  defp clean_secret(_), do: ""

  defp gen_secret, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp sanitize_display_name(name) when is_binary(name) do
    name |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, @display_name_max)
  end

  defp sanitize_display_name(_), do: ""

  defp sanitize_color(color) when is_binary(color),
    do: if(color in @character_colors, do: color, else: @default_color)

  defp sanitize_color(_), do: @default_color

  defp sanitize_message(text) when is_binary(text) do
    text |> String.trim() |> String.slice(0, @message_max)
  end

  defp sanitize_message(_), do: ""

  defp clamp(x) when is_number(x), do: x |> max(@min_x) |> min(@max_x)
  defp clamp(_), do: nil

  defp random_spawn_x, do: @min_x + :rand.uniform() * (@max_x - @min_x)

  defp now_ms, do: System.system_time(:millisecond)
end
