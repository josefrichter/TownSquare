// Core realtime-protocol parity test for the BEAM backend.
//
// These assertions are lifted from the original Node `scripts/smoke-test.js`
// (the default-scene section of `main()`), pointed at the Elixir server. They
// exercise the parts of the wire protocol the BEAM port reimplements: identity
// dedup across tabs, the peer snapshot, join/leave, browserId never leaking,
// move/say/typing/action/profile/reading, chat rate-limit, text cap, seat
// arbitration, the reconnect grace window, and multi-tab away state.
//
// Out of scope here (intentionally — boring CRUD where the runtime is moot):
// the site registry, admin API, moderation, the world map, IP rate limiting,
// proof-of-work, and ambient birds.
//
// Usage: TOWNSQUARE_WS_URL=ws://127.0.0.1:8788/live node parity/core-smoke.mjs
import WebSocket from "ws";

const SERVER_URL = process.env.TOWNSQUARE_WS_URL || "ws://127.0.0.1:8788/live";
const HTTP_ORIGIN = process.env.TOWNSQUARE_HTTP_ORIGIN || "http://127.0.0.1:8788";

function socketOptions(origin) {
  return origin ? { headers: { Origin: origin } } : undefined;
}

function connect({ x, browserId, browserSecret = "", origin = "", displayName = "", color = "", readingLabel, readingUrl }) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(SERVER_URL, socketOptions(origin));
    const seen = [];
    let joined = false;
    ws.on("open", () => {
      const init = { type: "init", x, browserId, displayName, color };
      if (browserSecret) init.browserSecret = browserSecret;
      if (typeof readingLabel === "string") init.readingLabel = readingLabel;
      if (typeof readingUrl === "string") init.readingUrl = readingUrl;
      ws.send(JSON.stringify(init));
    });
    ws.on("message", (buffer) => {
      const message = JSON.parse(String(buffer));
      seen.push(message);
      if (message.type === "hello") {
        joined = true;
        resolve({ ws, seen, id: message.id, hello: message });
      }
    });
    ws.on("error", reject);
    ws.on("close", (code, reason) => {
      if (!joined) reject(new Error(`${browserId} closed before hello (${code}: ${reason})`));
    });
  });
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(check, message, { timeout = 2500, interval = 25 } = {}) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    if (check()) return true;
    await delay(interval);
  }
  throw new Error(message);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function findLast(messages, predicate) {
  for (let i = messages.length - 1; i >= 0; i -= 1) if (predicate(messages[i])) return messages[i];
  return null;
}

async function main() {
  const first = await connect({
    x: 0.25,
    browserId: "browser-a",
    origin: HTTP_ORIGIN,
    displayName: "  Ada    Lovelace  ",
    color: "#3f7f63",
    readingLabel: "  Launch    notes  ",
    readingUrl: `${HTTP_ORIGIN}/notes/launch`,
  });
  const secondSameBrowser = await connect({
    x: 0.75,
    browserId: "browser-a",
    origin: HTTP_ORIGIN,
    browserSecret: first.hello.browserSecret,
  });
  await delay(100);

  assert(first.id === secondSameBrowser.id, "same-browser tabs did not reuse one shared identity");
  assert(first.hello.displayName === "Ada Lovelace", "display name was not normalized on init");
  assert(first.hello.color === "#3f7f63", "character color was not accepted on init");
  assert(first.hello.readingLabel === "launch", "reading label was not derived from the URL on init");
  assert(first.hello.readingUrl === `${HTTP_ORIGIN}/notes/launch`, "reading URL was not accepted on init");
  assert(first.hello.readingActive === true, "reading should default to active on init");
  assert(typeof first.hello.browserSecret === "string" && first.hello.browserSecret.length > 0, "hello did not include browser secret");
  assert(secondSameBrowser.hello.displayName === "Ada Lovelace", "same-browser tab did not inherit display name");
  assert(secondSameBrowser.hello.color === "#3f7f63", "same-browser tab did not inherit character color");
  assert(secondSameBrowser.hello.readingLabel === "launch", "same-browser tab did not inherit reading label");
  assert(secondSameBrowser.hello.peers.length === 0, "same-browser tab should not see itself as a peer");
  assert(!first.seen.some((m) => m.type === "join"), "same-browser tab incorrectly triggered a join event");

  const third = await connect({ x: 0.62, browserId: "browser-b", origin: HTTP_ORIGIN });
  await delay(100);

  assert(third.hello.peers.length === 1, "third client should see one existing visitor, not one per tab");
  assert(third.hello.peers[0].displayName === "Ada Lovelace", "peer snapshot did not include display name");
  assert(third.hello.peers[0].color === "#3f7f63", "peer snapshot did not include character color");
  assert(third.hello.peers[0].readingLabel === "launch", "peer snapshot did not include reading label");
  assert(!Object.hasOwn(third.hello.peers[0], "browserId"), "peer snapshot leaked browserId");
  assert(first.seen.some((m) => m.type === "join" && m.peer.id === third.id), "first client did not observe different-browser join");
  const joinBroadcast = first.seen.find((m) => m.type === "join" && m.peer?.id === third.id);
  assert(joinBroadcast && !Object.hasOwn(joinBroadcast.peer, "browserId"), "join broadcast leaked browserId");

  const impersonator = await connect({ x: 0.8, browserId: "browser-a", origin: HTTP_ORIGIN });
  assert(impersonator.id !== first.id, "stolen browserId reused victim visitor id");
  assert(impersonator.hello.displayName !== "Ada Lovelace", "stolen browserId hijacked victim profile");

  // --- reading updates (server derives label, ignores client label) ---
  secondSameBrowser.ws.send(JSON.stringify({ type: "reading", readingLabel: "API reference", readingUrl: `${HTTP_ORIGIN}/docs/api` }));
  await delay(100);
  assert(first.seen.some((m) => m.type === "reading" && m.id === first.id && m.readingLabel === "api" && m.readingUrl === `${HTTP_ORIGIN}/docs/api`), "reading update did not propagate to same-browser sibling");
  assert(third.seen.some((m) => m.type === "reading" && m.id === first.id && m.readingLabel === "api"), "reading update did not propagate to other visitors");
  assert(!third.seen.some((m) => m.type === "reading" && m.readingLabel === "API reference"), "server accepted a client-controlled reading label");

  // one inactive tab should not mark the shared visitor away
  secondSameBrowser.ws.send(JSON.stringify({ type: "reading", readingLabel: "API reference", readingUrl: `${HTTP_ORIGIN}/docs/api`, readingActive: false }));
  await delay(100);
  assert(!third.seen.some((m) => m.type === "reading" && m.id === first.id && m.readingActive === false), "one inactive same-browser tab should not mark the shared visitor away");
  // every tab inactive -> away propagates
  first.ws.send(JSON.stringify({ type: "reading", readingLabel: "API reference", readingUrl: `${HTTP_ORIGIN}/docs/api`, readingActive: false }));
  await delay(100);
  assert(third.seen.some((m) => m.type === "reading" && m.id === first.id && m.readingActive === false), "reading inactive did not propagate when every tab was inactive");

  // --- profile ---
  secondSameBrowser.ws.send(JSON.stringify({ type: "profile", displayName: "Ada", color: "#3f6fb5" }));
  await delay(100);
  assert(first.seen.some((m) => m.type === "profile" && m.id === first.id && m.displayName === "Ada" && m.color === "#3f6fb5"), "profile update did not propagate to same-browser sibling");
  assert(third.seen.some((m) => m.type === "profile" && m.id === first.id && m.displayName === "Ada" && m.color === "#3f6fb5"), "profile update did not propagate to other visitors");

  // --- move + typing ---
  secondSameBrowser.ws.send(JSON.stringify({ type: "move", x: 0.58 }));
  await delay(100);
  secondSameBrowser.ws.send(JSON.stringify({ type: "typing", typing: true }));
  await delay(100);
  assert(third.seen.some((m) => m.type === "typing" && m.id === first.id && m.typing === true), "different browser did not observe typing start");
  secondSameBrowser.ws.send(JSON.stringify({ type: "typing", typing: false }));
  await delay(100);
  assert(third.seen.some((m) => m.type === "typing" && m.id === first.id && m.typing === false), "different browser did not observe typing stop");

  // --- say + chat rate-limit ---
  secondSameBrowser.ws.send(JSON.stringify({ type: "say", text: "hello from shared browser" }));
  await delay(100);
  secondSameBrowser.ws.send(JSON.stringify({ type: "say", text: "this should be rate-limited away" }));
  await delay(100);
  assert(first.seen.some((m) => m.type === "move" && m.id === first.id), "same-browser move did not propagate to sibling tab");
  assert(first.seen.some((m) => m.type === "say" && m.id === first.id), "same-browser chat did not propagate to sibling tab");
  assert(third.seen.some((m) => m.type === "say" && m.id === first.id), "different browser did not observe shared visitor chat");
  assert(!third.seen.some((m) => m.type === "say" && m.id === first.id && m.text === "this should be rate-limited away"), "chat rate limit did not suppress a rapid second message");

  // --- actions ---
  secondSameBrowser.ws.send(JSON.stringify({ type: "action", action: "jump" }));
  await delay(100);
  assert(first.seen.some((m) => m.type === "action" && m.id === first.id && m.action === "jump"), "same-browser jump did not propagate to sibling tab");
  assert(third.seen.some((m) => m.type === "action" && m.id === first.id && m.action === "jump"), "different browser did not observe shared visitor jump");

  await delay(600);
  third.ws.send(JSON.stringify({ type: "move", x: 0.6 }));
  await delay(100);
  secondSameBrowser.ws.send(JSON.stringify({ type: "action", action: "raise-hand" }));
  await delay(100);
  assert(third.seen.some((m) => m.type === "action" && m.id === first.id && m.action === "raise-hand"), "different browser did not observe shared visitor raise-hand");

  third.ws.send(JSON.stringify({ type: "action", action: "high-five", targetId: first.id }));
  await delay(100);
  assert(first.seen.some((m) => m.type === "action" && m.id === third.id && m.action === "high-five" && m.targetId === first.id), "target visitor did not observe high-five");
  assert(secondSameBrowser.seen.some((m) => m.type === "action" && m.id === third.id && m.action === "high-five" && m.targetId === first.id), "same-browser tab did not observe high-five targeting shared visitor");

  // --- chat text cap ---
  await delay(1600);
  secondSameBrowser.ws.send(JSON.stringify({ type: "say", text: "x".repeat(200) }));
  await delay(100);
  const truncated = findLast(third.seen, (m) => m.type === "say" && m.id === first.id);
  assert(truncated && truncated.text.length === 140, "chat text was not capped to 140 characters");

  // --- bench seats ---
  secondSameBrowser.ws.send(JSON.stringify({ type: "move", x: 0.2 }));
  await delay(100);
  secondSameBrowser.ws.send(JSON.stringify({ type: "settle", propId: "bench" }));
  await delay(100);
  const firstBench = findLast(first.seen, (m) => m.type === "move" && m.id === first.id && m.pose === "sitting");
  assert(firstBench, "same-browser bench settle did not propagate to sibling tab");
  assert(findLast(third.seen, (m) => m.type === "move" && m.id === first.id && m.pose === "sitting"), "bench settle did not propagate to other visitors");

  third.ws.send(JSON.stringify({ type: "move", x: 0.2 }));
  await delay(100);
  third.ws.send(JSON.stringify({ type: "settle", propId: "bench" }));
  await delay(100);
  const thirdSeat = findLast(first.seen, (m) => m.type === "move" && m.id === third.id && m.pose === "sitting");
  assert(thirdSeat, "second visitor did not settle onto the bench");
  assert(Math.abs(thirdSeat.x - firstBench.x) > 0.005, "bench seat allocation reused an occupied seat");

  // --- tree seats ---
  secondSameBrowser.ws.send(JSON.stringify({ type: "move", x: 0.8 }));
  await delay(100);
  secondSameBrowser.ws.send(JSON.stringify({ type: "settle", propId: "tree" }));
  await delay(100);
  const firstTree = findLast(first.seen, (m) => m.type === "move" && m.id === first.id && m.pose === "resting" && m.propId === "tree");
  assert(firstTree, "tree settle did not propagate to sibling tab");

  third.ws.send(JSON.stringify({ type: "move", x: 0.8 }));
  await delay(100);
  third.ws.send(JSON.stringify({ type: "settle", propId: "tree" }));
  await delay(100);
  const thirdTree = findLast(first.seen, (m) => m.type === "move" && m.id === third.id && m.pose === "resting" && m.propId === "tree");
  assert(thirdTree, "second visitor did not settle under the tree");
  assert(Math.abs(thirdTree.x - firstTree.x) > 0.005, "tree seat allocation reused an occupied seat");

  // --- leave semantics: one tab closing keeps the shared visitor ---
  secondSameBrowser.ws.close();
  await delay(100);
  assert(!first.seen.some((m) => m.type === "leave" && m.id === first.id), "closing one same-browser tab incorrectly removed the shared visitor");

  // --- last tab closing removes the visitor after the reconnect grace window ---
  third.ws.close();
  await waitFor(() => first.seen.some((m) => m.type === "leave" && m.id === third.id), "first client did not observe different-browser leave", { timeout: 4000 });

  first.ws.close();
  impersonator.ws.close();
  console.log("Core parity test passed.");
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
