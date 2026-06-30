# TownSquare — BEAM backend

An Elixir/OTP port of TownSquare's **realtime core**, talking the exact same
WebSocket protocol as the original Node server, so the unchanged vanilla-JS
widget in `public/` works against it without a single edit.

This exists to make a point (see the [write-up](https://josefrichter.design/blog/townsquare-beam)):
realtime presence is the BEAM's home turf, and porting the core makes a whole
category of the original's `docs/tech-debt.md` items disappear by construction.

## Stack

No web framework, to match the original's `http` + `ws` altitude:

- **Bandit** — HTTP/WebSocket server
- **Plug** — routing (`/healthz`, `/live` upgrade, static assets)
- **WebSock** — the per-connection behaviour (four callbacks, no macros)
- **Jason** — JSON

No Phoenix, no LiveView, no Channels, **no pubsub/presence library** — on a
single node the scene GenServer *is* the presence store and broadcast is a loop.

## Layout

| File | Role |
|---|---|
| `lib/town_square_beam/application.ex` | supervision tree (Registry + DynamicSupervisor of scenes + Bandit) |
| `lib/town_square_beam/router.ex` | HTTP edge; serves the widget, upgrades `/live` |
| `lib/town_square_beam/socket.ex` | `WebSock` connection handler + per-connection throttles |
| `lib/town_square_beam/scene.ex` | one GenServer per scene: roster, broadcast, seats, disconnect via `Process.monitor` |
| `lib/town_square_beam/reading.ex` | server-side reading-label derivation (ported from `server.js`) |
| `lib/town_square_beam/props.ex` | default-scene bench/tree seat geometry |

## Run

```bash
mix deps.get
PORT=8788 mix run --no-halt
# health check:
curl http://127.0.0.1:8788/healthz   # -> ok
```

## Configuration

All runtime config is environment-driven (`config/runtime.exs`), so one build
runs anywhere:

| Env var | Default | Purpose |
|---------|---------|---------|
| `PORT` | `8788` | HTTP/WebSocket listen port |
| `TOWNSQUARE_ALLOWED_ORIGINS` | _(empty = any)_ | Comma-separated origins allowed to open a `/live` socket. Set it in production to lock the socket to your site. |
| `TOWNSQUARE_MAX_CONNECTIONS_PER_IP` | `30` | New `/live` connections allowed per IP per 10s window (`0` disables). |
| `TOWNSQUARE_TRUST_PROXY` | `false` | When `true`, read the client IP from `x-forwarded-for` (only behind a reverse proxy you control). |

## Deploy

A self-contained OTP release (no Elixir on the host):

```bash
docker build -t townsquare-beam .
docker run -p 8788:8788 \
  -e TOWNSQUARE_ALLOWED_ORIGINS=https://your-site.example \
  townsquare-beam
```

The image bundles the BEAM, the release, and the widget assets; it runs on any
container host. `config/runtime.exs` reads the table above at boot.

## Tests

Pure unit tests:

```bash
mix test
```

Protocol parity against the original's own smoke assertions (start the server
first, in another shell):

```bash
node parity/core-smoke.mjs            # -> "Core parity test passed."
```

## Scope

Ported: presence, identity dedup across tabs (+ anti-spoof secret), movement,
chat (rate-limit + 140-char cap), typing, gestures (jump / raise-hand /
high-five with proximity), reading-state, bench/tree seat arbitration,
join/leave with a reconnect-grace window.

Intentionally **not** ported (ordinary CRUD where the runtime is moot): the
site registry, admin API, moderation, the world map, IP rate-limiting,
proof-of-work, the Plausible proxy, plugins, and ambient birds. The point of
the exercise is the realtime core, which is where the BEAM's advantages live.
