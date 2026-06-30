# TownSquare is a BEAM app that happens to be written in Node

*Why a realtime-presence widget should default to Elixir/OTP — and what falls out when you port its core. Written for the person who'd reach for Node here without thinking twice. I almost did too.*

---

[TownSquare](https://townsquare.cauenapier.com/) is a lovely little thing: drop in a script tag and a strip of stick figures appears at the bottom of your page, one per visitor reading right now. You can walk around, see who's on the same article, wave, chat. No accounts, no history. Caue Napier built it, [open-sourced it](https://cauenapier.com/blog/townsquare_release/), and runs a free public server. Generous.

## What the app actually is

Strip it down:

- Many long-lived WebSocket connections.
- Mostly-independent **scenes** — one per site — each a roster of who's present.
- Per-visitor state (position, page, recent messages).
- "Many tabs = one visitor."
- Broadcast within a scene; clean up the instant someone leaves.

What caught my eye is that it's almost a perfect use case for the BEAM — and, at the same time, a genuinely troublesome one for Node.

That list up there is an actor-per-entity system with presence and pub/sub — the thing Erlang was *built* for: Ericsson needed millions of isolated little state machines surviving each other's crashes. Coincidentally, they created a system that turned out to be perfect for today's realtime multiuser (and multiagent) world wide web.

Reading the code — and especially its own `docs/tech-debt.md` — confirmed it. The author had already run a careful self-audit, and the list reads like a catalogue of exactly the troubles this shape causes on Node. Below, each BEAM idea is paired with the line(s) from that list it makes disappear.

So I forked it and rewrote the realtime core in Elixir — same wire protocol, the **exact same browser client, byte for byte** — and ran TownSquare's own protocol tests against it. The rest of this post is the *why*.

## The one idea you have to swallow first

In Node your whole server is **one process, one event loop, one heap**. Every connection, scene, and visitor is an object in that shared space, taking turns on a single thread:

```
NODE — one process, one loop, one heap

+---------------------------------------+
|  event loop -> cb -> cb -> cb -> ...  |
|  scenes . identities . sockets        |
+---------------------------------------+

  ^ all shared, mutated in place
  one throw in any callback can drop everything
```

On the BEAM you get **millions of tiny processes**, each with its own heap and mailbox, scheduled preemptively, sharing nothing. They touch each other only by sending messages:

```
BEAM — many tiny processes, share nothing

+------------+  +------------+  +------------+             +------------+
|  socket A  |  |  socket B  |  |  socket C  |   --msg-->  |  scene     |
|  own heap  |  |  own heap  |  |  own heap  |             |  roster    |
|  own mbox  |  |  own mbox  |  |  own mbox  |             |  own heap  |
+------------+  +------------+  +------------+             +------------+

  a crash in one stays in that one
```

If that picture lands, everything below is just consequences.

## The principles, mapped to the tech-debt

Here's the BEAM mental model in five pieces. Against each is the line (or two) from TownSquare's own `docs/tech-debt.md` it makes disappear — the author's words, not mine.

### 1 · A connection is a process → crashes are contained

```
Node:  bad frame -> throw -> unhandled -> every socket on every site drops
BEAM:  bad frame -> that ONE process crashes -> its supervisor restarts it
```

> **T1** (top priority) — *"One unguarded throw kills every connection — no try/catch around request dispatch, no `uncaughtException` guard, no SIGTERM drain."*

Each connection is its own process, so an unguarded throw crashes that one socket and its supervisor restarts it. There's nothing to wrap and no global net to bolt on — the bug class doesn't exist.

### 2 · State is a process you message → the scene *is* the roster

In Node a scene is *data*: a `scenes` Map → an `identities` Map → a `Set` of sockets, all mutated in place. On the BEAM a scene is a **GenServer** — a process whose state map *is* the roster. You never reach in and read it; you send it a message and it updates itself:

```
socket --{:move, pid, x}--> scene process
   the scene then updates its own state.ids[id]
   and broadcasts the change to the sockets
   (one message at a time -> no locks, no races)
```

One process handles one message at a time, so there are **no locks and no races** — and the roster and the pub/sub are the same process, with no separate presence library to keep in sync. (No tech-debt line here: this is the backbone the rest stand on.)

### 3 · Death is a message → disconnect handles itself

This is the one that deletes a whole category of bugs. When a socket joins, the scene calls `Process.monitor(pid)`. When that process exits — tab closed, laptop slept, crash, network drop — the scene receives one message:

```
{:DOWN, _ref, :process, pid, _}      <- "that socket is gone"
```

> **H5** — *"Replaced WebSockets leak on reconnect — old socket listeners not removed/closed."*
>
> **H7** — *"Leave timers fire against deleted scenes — not cleared on site/scene deletion or shutdown."*

That message *is* the leave event. There's no `ws.on('close')` to remember to wire up — that's **H5** — and the reconnect-grace timer is created *inside* the scene with `Process.send_after(self(), …)`, so it can't outlive the scene it guards — that's **H7**. Both gone by construction.

### 4 · "Let it crash" → supervisors, not safety nets

```
            Supervisor
           /     |      \
       scene   scene   Bandit --> one process per connection

   one process crashes -> only that one is restarted
```

> **T5** — *"Plugin registration runs at module top-level with no try/catch — one malformed plugin crashes boot."*

Each scene starts as a supervised process; one that fails to start is isolated and logged, not fatal to the others or to boot. You stop writing defensive `try/catch` as a load-bearing safety net — isolation plus restart *is* the model.

### 5 · Preemptive scheduling → two more just vanish

> **T3** — *"Synchronous full-registry `saveSites()` … on the WS/admin hot path blocks the event loop."*
>
> **H6** — *"Unbounded in-memory growth — per-IP-per-scene activity map and scenes never bounded."*

There's no shared event loop to block: a process doing slow disk I/O can't stall message delivery to any other, so **T3** isn't a hazard. And an empty scene process terminates and the BEAM reclaims its heap, so the hand-rolled eviction behind **H6** becomes "let the process exit."

That's six tech-debt items and six bug classes that don't survive the move — none about cleverness, all about which runtime you started from.

## Now the code is boring — and that's the point

Because the runtime does the hard parts, the port is small. The socket is four callbacks:

```elixir
def init(opts), do: {:ok, %{scene: Scene.ensure(opts[:scene_key]), id: nil}}

def handle_in({text, [opcode: :text]}, state),   # ~ ws "message"
  do: dispatch(Jason.decode!(text), state)

def handle_info({:ws_push, payload}, state),     # a scene broadcast → this tab
  do: {:push, {:text, payload}, state}

def terminate(_reason, _state), do: :ok          # ~ ws "close" (scene cleans up via monitor)
```

And the broadcast — the entire "pub/sub" — is a loop: `JSON.stringify` once, send to many.

```elixir
defp broadcast(state, frame, except: pid) do
  payload = Jason.encode!(frame)
  for i <- Map.values(state.ids), {p, _} <- i.sockets, p != pid,
    do: send(p, {:ws_push, payload})
end
```

No Phoenix, no Channels, no `phoenix_pubsub`, no `Phoenix.Presence` — on one node they're redundant. Same altitude as Node's `http` + `ws`, so the only variable left between the two is the runtime.

## Proof: their own tests, green

I pointed TownSquare's *own* `smoke-test.js` — same `ws` client, same JSON frames — at the Elixir server:

```
$ node beam/parity/core-smoke.mjs
Core parity test passed.
```

That covers identity dedup across tabs, the peer snapshot, `browserId` never leaking, join/leave, move/say/typing/gestures/reading, server-derived reading labels, rate-limiting, the 140-char cap, seat arbitration, and the multi-tab grace-window semantics. The same client can't tell the two servers apart.

## What I didn't port — and why that's the argument

The Elixir core is ~740 lines; `server.js` is ~3,300. That's **not** a fair 4.5× — `server.js` also has the site registry, admin API, moderation, the world map, IP limits, proof-of-work, a Plausible proxy, plugins. I ported none of it.

That omission *is* the point: all of it is ordinary HTTP CRUD where the runtime doesn't matter — roughly the same size in any language. The BEAM's advantage is concentrated entirely in the realtime core, which is exactly the part where the tech-debt list evaporates. The boring 80% stays boring everywhere; the hard 20% is the 20% the BEAM was designed for.

## When I'd reach for it

Greenfield with the words *presence*, *realtime*, *multiplayer*, or *chat* in the brief: the BEAM, without a second thought. An existing, working, not-growing product: leave it — rewriting working software is usually a mistake.

One honest caveat on the *webring* Caue wants next: today "walk to a neighbour" is just a navigation to their site, which is correct and needs no special runtime — and on his single hosted server every square is already one process anyway. The BEAM only pulls ahead if this becomes a *federation* of independently-run squares sharing live presence, where an all-BEAM cluster gets cross-node messaging for free (`:pg`, in the standard library). Real, but a narrower claim than it first sounds.

Don't reach for Node by reflex. Reach for the runtime built for exactly this, and spend your cleverness on the part your users actually see.

---

*The fork, the Elixir server, and the parity test are at [`beam/`](./beam) in [this fork](https://github.com/josefrichter/TownSquare). Huge thanks to [Caue Napier](https://cauenapier.com) for building TownSquare in the open — go [add it to your site](https://townsquare.cauenapier.com/).*
