# Clovyre MCP

A cloud bridge between a **live Roblox client** and a **remote MCP agent** (Claude, Claude Code,
Codex, or any Streamable HTTP MCP client).

Everything runs in the browser and the cloud. No Roblox Studio, no local server, no Node.js on your
machine, no terminal. It works from an iPad.

---

## What it does

You create a temporary session on the Clovyre web app. It hands you two things:

1. A **loadstring** to paste into your executor, which connects your live Roblox client out over a
   secure WebSocket.
2. A **remote MCP endpoint** plus a bearer token, which you give to your AI agent.

Your agent can then explore the replicated instance tree, read safe properties and attributes,
inspect replicated scripts, and query runtime state — everything your client can already see.

## Architecture

```
                   Live Roblox client
                (executor runs client.lua)
                            |
                            |  wss://<deployment>/ws/roblox
                            |  auth: hello frame carries the Roblox token
                            v
        +-----------------------------------------------+
        |            Clovyre backend (Node)             |
        |                                               |
        |  Next.js dashboard + session API              |
        |  Roblox WebSocket gateway                     |
        |  Session broker + pending-command registry    |
        |  Tool registry + capability registry          |
        |  Audit log · rate limiter · credential store  |
        |  Remote MCP server (Streamable HTTP)          |
        +-----------------------------------------------+
                            ^
                            |  https://<deployment>/api/mcp/<sessionId>
                            |  auth: Authorization: Bearer <MCP token>
                            |
              Claude · Claude Code · Codex · other MCP client
```

One Node process serves all of it. The Next.js app and the WebSocket gateway share a single HTTP
server, which is why Clovyre needs a long-lived container rather than serverless functions.

## Features

- **Session model with four independent credentials** — Roblox, MCP, browser owner, CSRF. Each is
  256 bits of entropy; only HMAC digests are retained; each can be revoked on its own.
- **Replicated instance explorer** — lazy children, depth-limited trees, name search, class filters,
  attributes, CollectionService tags, and a curated safe-property registry.
- **Script inspection** — LocalScripts and replicated ModuleScripts, each labelled honestly as
  `source`, `decompiled`, `bytecode` or `unavailable`.
- **Runtime tools** — players, local player, character, camera, workspace summary, captured logs.
- **Capability-aware tool surface** — decompile, `getgc`, `getsenv`, `getconnections` and
  `getloadedmodules` tools appear only when the executor genuinely provides them.
- **Privileged tools off by default** — Luau execution, executor globals, the remote spy and
  mutation tools all require an explicit grant made by the session owner in the browser. A grant
  then stands until the owner turns it off: enable it once and the agent keeps working. Set
  `PRIVILEGE_TTL_MINUTES` above 0 if you want grants to clear themselves instead.
- **Several clients per session** — everyone who runs the script joins the same session. Re-running
  it in one executor replaces that client; a second person joins alongside. Once more than one is
  attached, a tool call must name its client, and a call that does not fails with
  `CLIENT_AMBIGUOUS` and the roster rather than guessing which person's game to act on.
- **Silent by default** — the bridge prints nothing to the executor console unless you turn console
  output on for the session. Logs are still buffered on the client and readable with
  `clovyre_get_logs`, so quiet costs no diagnostics.
- **Live observation** — install watchers on properties, attributes and children and poll the
  changes they record, instead of re-reading the same instance and missing what happened in between.
- **Remote spy** — record the RemoteEvent and RemoteFunction calls the client sends, with serialized
  arguments. Observation only: Clovyre has no tool that fires a remote.
- **GUI inspection** — the on-screen hierarchy with text, visibility and absolute geometry resolved.
- **MCP resources** — attach `clovyre://session`, `clovyre://services`, `clovyre://tree` and
  `clovyre://scripts` directly to a conversation instead of spending a tool call.
- **Full audit trail** — every command, duration, outcome and connection event, with secrets
  redacted before storage.
- **Live dashboard** — connection status, capability matrix, tool availability, activity feed,
  credential management and one-tap termination. Built for iPad first.

## Limitations

These are properties of the design, not bugs:

- **Only replicated, client-visible state is reachable.** `ServerScriptService`, `ServerStorage`,
  server `Script`s and server memory are not replicated to a client and are therefore unreachable.
- **Decompilation is best effort.** Output labelled `decompiled` is not guaranteed to match the
  original source and may be wrong. Clovyre never presents it as original source.
- **Executor APIs vary.** Tools depending on optional executor functions are disabled when those
  functions are absent. That is reported, not hidden.
- **`clovyre_execute_luau` is dangerous and disabled by default.** It is not sandboxed. The
  "executor globals" toggle is a convenience filter, not a security boundary.
- **Local mutations do not change server-authoritative state.** The Roblox server will typically
  ignore or overwrite them.
- **Ownership verification is not implemented.** Clovyre does not check that you own or are
  authorised to test the experience you connect it to. The architecture has a hook for it; the check
  is not enabled.
- **A session outlives the process, a connection does not.** Sessions are written through to
  Postgres, so a restart or redeploy preserves the session and its credentials. The live Roblox
  WebSocket, pending commands and observation buffers are not restored — rerun the loadstring to
  reconnect.

## Live deployment

**https://clovyre-mcp.onrender.com**

Running on a Render free instance, which means two things worth knowing before you rely on it:

- The service **spins down after roughly 15 minutes without traffic**, and the first request after
  that takes ~30 seconds to wake it. Your session survives the spin-down; the Roblox connection does
  not, so rerun the loadstring afterwards.
- Sessions live in a free Postgres instance, which Render expires 30 days after creation. When it
  goes, so does every stored session.

For anything beyond evaluation, move to a paid instance type — `render.yaml` documents the settings.

## Quick start (as a user)

1. Open the deployment and tap **Create session**.
2. Copy the generated loadstring.
3. Run it in your executor with your experience open.
4. Watch the dashboard flip to **Roblox connected**.
5. Copy the MCP endpoint and bearer token into your agent.

The loadstring looks like this (tokens are session-specific and shown once):

```lua
getgenv().ClovyreConfig = {
    BaseUrl = "https://<deployment>",
    SessionId = "cs_XXXXXXXXXXXXXXXXXXXX",
    RobloxToken = "crx_..."
}
loadstring(game:HttpGet("https://<deployment>/client.lua"))()
```

Running it twice cleans up the previous connection instead of creating a duplicate. Call
`getgenv().ClovyreDisconnect()` to stop the bridge.

## Connecting Claude

Clovyre speaks MCP over **Streamable HTTP**. A session is the thing you configure your agent
against, and a session is durable: once `DATABASE_URL` is set, it survives restarts and redeploys.
So you configure the endpoint **once per session** and it keeps working until you terminate that
session. Deleting a session and creating a new one means reconfiguring your agent — that is the
whole contract, and it is deliberate: the URL carries the identity, so a URL that outlived its
session would be a URL pointing at somebody else's Roblox client.

The Roblox loadstring can be regenerated as often as you like without touching the MCP config.

### Header-capable clients (Claude Code, Codex)

```
POST https://<deployment>/api/mcp/<sessionId>
Authorization: Bearer <your cmk_ MCP token>
```

### Session-only URL (claude.ai / desktop)

Claude's custom connector screen accepts a URL and offers no field for an authorization header, so
Clovyre also publishes the endpoint with the credential in the path:

```
https://<deployment>/api/mcp/<sessionId>/<MCP token>
```

1. Settings → Connectors → **Add custom connector**
2. Paste that URL. Leave everything else blank.
3. Save, open a chat, and ask Claude to run `clovyre_session_info`.

The dashboard generates this URL for you and offers it as a one-tap copy.

**The trade-off, stated plainly:** a credential in a URL path is visible to proxy and platform
access logs, and anyone holding the URL can drive the session. It is mitigated by the credential
being session-scoped, expiring with the session, and being regenerable or revocable from the
dashboard at any moment. If your client can send headers, prefer the forms below.

### Claude Code

```bash
claude mcp add --transport http clovyre https://<deployment>/api/mcp/<sessionId> \
  --header "Authorization: Bearer <MCP token>"
```

### Config file (Codex and other HTTP-capable clients)

One endpoint per session, authenticated by a bearer token bound to that session:

```
POST https://<deployment>/api/mcp/<sessionId>
Authorization: Bearer <session MCP token>
Content-Type: application/json
```

For clients that accept a remote HTTP MCP server:

```json
{
  "mcpServers": {
    "clovyre": {
      "type": "http",
      "url": "https://<deployment>/api/mcp/<sessionId>",
      "headers": { "Authorization": "Bearer <session MCP token>" }
    }
  }
}
```

For desktop clients that only speak stdio, the dashboard also generates an `mcp-remote` proxy
configuration. The remote HTTP form is preferred — it needs no local process, which is the point.

Start with `clovyre_session_info` to confirm the bridge is live.

### Losing a token is recoverable

Tokens are shown once and stored only as digests, so the original genuinely cannot be redisplayed.
The dashboard therefore **generates a fresh one automatically** when a tab has none — after a
reload, for instance — and offers an explicit _Generate a new script_ / _Generate a new MCP
credential_ control at any time. Regenerating never disturbs a live Roblox bridge; it only
invalidates the old credential for future connections, and it asks for confirmation first if
something is currently connected with it.

## Tools

**Session** — `clovyre_session_info`, `clovyre_list_clients`, `clovyre_list_capabilities`,
`clovyre_ping`, `clovyre_broadcast_tool`, `clovyre_compare_clients`

**Discovery** — `clovyre_get_services`, `clovyre_get_children`, `clovyre_get_descendants`,
`clovyre_find_instances`, `clovyre_inspect_instance`, `clovyre_get_attributes`, `clovyre_get_tags`,
`clovyre_get_property`, `clovyre_get_properties`, `clovyre_search_properties`,
`clovyre_get_instance_tree`, `clovyre_get_gui_tree`, `clovyre_find_gui_elements`,
`clovyre_get_screen_text`, `clovyre_get_ancestors`, `clovyre_get_tag_index`,
`clovyre_list_remotes`

**Scripts** — `clovyre_list_scripts`, `clovyre_inspect_script`, `clovyre_search_scripts`,
`clovyre_get_script_dependencies`, `clovyre_get_loaded_modules`

**Runtime** — `clovyre_get_players`, `clovyre_get_local_player`, `clovyre_get_character`,
`clovyre_get_camera`, `clovyre_get_workspace_summary`, `clovyre_get_logs`,
`clovyre_get_connections`, `clovyre_get_gc_summary`, `clovyre_inspect_environment`,
`clovyre_raycast`, `clovyre_query_region`, `clovyre_get_stats`, `clovyre_get_teams`,
`clovyre_get_leaderstats`, `clovyre_get_backpack`, `clovyre_get_lighting`, `clovyre_get_sounds`,
`clovyre_get_animations`

**Observation** — `clovyre_watch_start`, `clovyre_watch_stop`, `clovyre_list_watches`,
`clovyre_get_watch_events`, `clovyre_wait_for`, `clovyre_remote_spy_start`,
`clovyre_remote_spy_stop`, `clovyre_get_remote_calls`

**Activity** — `clovyre_get_recent_activity`, `clovyre_get_recent_errors`,
`clovyre_cancel_command`

**Privileged (owner grant required)** — `clovyre_execute_luau`, `clovyre_remote_spy_start`,
`clovyre_set_property`, `clovyre_set_properties`, `clovyre_set_attribute`,
`clovyre_create_instance`, `clovyre_clone_instance`, `clovyre_destroy_instance`,
`clovyre_reparent_instance`, `clovyre_set_tag`, `clovyre_set_camera`

`clovyre_list_remotes` maps the RemoteEvents and RemoteFunctions a game uses, and that is where it
stops: **there is no tool that fires a remote**, at any privilege level. Reading the interface a game
exposes is inspection; calling it is playing the game for someone. A test asserts the bridge never
grows one.

`clovyre_broadcast_tool` runs a single tool on every connected client at once, and accepts only
read-only, non-privileged ones — fanning a write out across several people's games is not something
one call should be able to express.

Privileged tools are hidden from `tools/list` until the session owner grants them in the browser, so
an agent cannot even attempt to call them.

Once granted, a privilege stays granted — there is no timer to re-arm. Revoking is a single toggle in
the dashboard and takes effect on the next tool call, and a banner stays visible for as long as any
privilege is live so a standing grant is never silent.

## Security considerations

- HTTPS and WSS only in production; secure, `httpOnly`, `SameSite=Lax` owner cookies.
- The public session id is an **address**, never an authenticator.
- Credentials are checked only against the session named in the request, which makes cross-session
  command routing structurally impossible.
- Owner mutations require a same-origin request plus a double-submit CSRF token.
- Every WebSocket frame is Zod-validated; unknown types, oversized payloads and binary frames are
  rejected.
- Per-session and per-address rate limits, command timeouts, concurrency caps and payload ceilings.
- Redaction layer scrubs credential-shaped values and sensitive header names before anything is
  logged, audited or displayed.
- CSP and secure headers on every response. No `NEXT_PUBLIC_*` variables exist — no secret can reach
  the browser bundle.

See [SECURITY.md](./SECURITY.md) for the reporting process and the full threat model.

## Development

Requires Node 20+.

```bash
npm ci
cp .env.example .env.local     # fill in SESSION_SECRET and TOKEN_HASH_SECRET
npm run dev                    # http://localhost:3000
```

| Script              | What it does                                                 |
| ------------------- | ------------------------------------------------------------ |
| `npm run dev`       | Development server with the WebSocket gateway attached       |
| `npm run build`     | Next.js production build plus the compiled TypeScript server |
| `npm start`         | Runs the compiled server; binds to `process.env.PORT`        |
| `npm run lint`      | ESLint                                                       |
| `npm run typecheck` | `tsc --noEmit` for both the app and the server               |
| `npm test`          | Vitest unit and integration suites                           |
| `npm run test:e2e`  | Playwright smoke tests on desktop and iPad viewports         |
| `npm run format`    | Prettier                                                     |

### Testing

- **Unit** — credentials, session lifecycle, expiry, privilege grants, protocol parsing, structured
  paths, serializer limits and cycles, redaction, rate limiting, safe-property registry, tool
  schemas and the MCP JSON-RPC surface.
- **Integration** — a real HTTP server, a real WebSocket upgrade, the real broker, and a **mock
  Roblox client** (`tests/helpers/mock-roblox-client.ts`) that can connect, advertise capabilities,
  answer commands, stall to force a timeout, emit malformed frames and disconnect. Roblox itself
  cannot run in CI, so this is where command routing, timeouts, cross-session isolation and
  disconnect handling are proven.
- **E2E** — landing page, session creation, loadstring visibility, copy feedback, disconnected
  status, owner isolation, health, `/client.lua`, MCP authentication and security headers.

## Deployment (Render)

Clovyre deploys as a single Render web service. `render.yaml` is a working blueprint.

- Build: `npm ci --include=dev && npm run build` (Render sets `NODE_ENV=production`, which would otherwise skip the devDependencies the build needs)
- Start: `npm start`
- Health check: `/api/health`
- Instance type: the live deployment uses `free`; sessions do not survive its spin-down.
- Instances: **1** — session state is in-process, so a second instance would not see the first
  instance's sessions. Scaling out requires a shared broker (Redis or equivalent).

After the first deploy, set `PUBLIC_BASE_URL` to the service URL so generated loadstrings and MCP
endpoints use the canonical origin.

`SESSION_SECRET` and `TOKEN_HASH_SECRET` should be generated by Render (`generateValue: true`) and
never committed. No deployment credential — Render API key, GitHub token — is ever read by the
application, written into source, or logged.

### Environment variables

See [.env.example](./.env.example) for the full annotated list. Every variable there is actually
read by the application; there are no unused placeholders. `DATABASE_URL` is the one that matters
most: without it Clovyre still runs, but sessions die with the process and every agent has to be
reconfigured after each deploy.

## Production limitations

- Single instance only. Live connections and pending commands are per-process, so a redeploy drops
  every Roblox client even though the sessions themselves survive.
- On the free instance type the service also spins down after ~15 minutes of inactivity, and the
  next request pays a cold-start delay.
- `TOKEN_HASH_SECRET` must stay stable. It keys the credential digests, so rotating it invalidates
  the tokens of every persisted session.
- No ownership verification.
- Rate limits are per-process and reset with the process.

## Repository layout

```
server/                  Node entry point and the Roblox WebSocket gateway
src/app/                 Next.js routes: dashboard, docs, API, /client.lua
src/components/          Interface primitives and session screens
src/lib/
  api/                   HTTP helpers, owner auth, CSRF, origin checks
  audit/                 Bounded per-session audit log
  mcp/                   MCP JSON-RPC server, availability, local tools
  protocol/              Versioned wire schemas and structured paths
  security/              Credentials, hashing, redaction, rate limiting
  serialization/         Roblox value normalisation and display
  sessions/              Session store, broker, view model, snippets
  tools/                 Tool registry, invocation path, safe properties
roblox/client.lua        The Roblox bridge served at /client.lua
tests/                   Unit, integration (with mock client) and E2E suites
docs/                    Architecture and protocol references
```

## Documentation

- [`docs/architecture.md`](./docs/architecture.md) — components, data flow, lifecycle
- [`docs/protocol.md`](./docs/protocol.md) — WebSocket and MCP wire formats
- [`SECURITY.md`](./SECURITY.md) — threat model and reporting
- [`CONTRIBUTING.md`](./CONTRIBUTING.md) — development workflow
- `/docs` on the deployment itself — the same material, rendered

## Licence

MIT. See [LICENSE](./LICENSE).

## Use responsibly

Clovyre reaches only what your own Roblox client already receives. Use it exclusively in experiences
you own or are explicitly authorised to test, and only connect agents you trust.
