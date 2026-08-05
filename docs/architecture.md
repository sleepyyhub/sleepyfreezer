# Clovyre MCP architecture

## Overview

Clovyre is one Node process that mediates between three parties: a live Roblox client, a browser
dashboard, and a remote MCP agent. They share exactly one thing — a session — and each authenticates
with its own credential.

```
Live Roblox client ──wss──▶ Clovyre backend ◀──https── MCP agent
                                  ▲
                                  │ https + owner cookie
                            Browser dashboard
```

## Components

| Component         | Location                                | Responsibility                                                                 |
| ----------------- | --------------------------------------- | ------------------------------------------------------------------------------ |
| Process entry     | `server/index.ts`                       | Boots Next.js, creates the HTTP server, attaches the gateway, handles shutdown |
| Roblox gateway    | `server/websocket-server.ts`            | Upgrade handling, hello authentication, frame validation, heartbeats, teardown |
| Session store     | `src/lib/sessions/store.ts`             | Lifecycle, credentials, privileges, expiry, sweeping                           |
| Session broker    | `src/lib/sessions/broker.ts`            | Owns the live transport per session and the pending-command registry           |
| Tool registry     | `src/lib/tools/registry.ts`             | Names, Zod schemas, capability and privilege requirements, timeouts            |
| Invocation path   | `src/lib/tools/invoke.ts`               | The single execution path shared by MCP and the dashboard                      |
| Capability gating | `src/lib/mcp/tool-availability.ts`      | Decides what a session may see and call, and why not                           |
| MCP server        | `src/lib/mcp/server.ts`                 | JSON-RPC 2.0 over Streamable HTTP                                              |
| Audit log         | `src/lib/audit/audit-log.ts`            | Bounded, redacted, per-session event trail                                     |
| Credentials       | `src/lib/security/tokens.ts`            | Generation, HMAC digests, constant-time comparison                             |
| Redaction         | `src/lib/security/redact.ts`            | Scrubs secrets from anything that leaves the process                           |
| Rate limiting     | `src/lib/security/rate-limit.ts`        | Fixed-window buckets per rule and key                                          |
| Serialisation     | `src/lib/serialization/roblox-value.ts` | Re-normalises untrusted client values with hard limits                         |
| Safe properties   | `src/lib/tools/safe-properties.ts`      | Curated per-class read allow-list                                              |
| Bridge            | `roblox/client.lua`                     | Executor adapter, serializer, tool handlers, reconnect logic                   |

Shared singletons (store, broker, rate limiter, config) are pinned to `globalThis`. The Next.js
bundle and the custom server load modules through different registries, so this is what guarantees
both see the same instance in the same process.

## Session lifecycle

1. **Create** — `POST /api/sessions` allocates a record, mints four credentials, returns the Roblox
   and MCP tokens exactly once, and sets the owner and CSRF cookies.
2. **Attach Roblox** — the bridge connects and sends `hello` with the session id and Roblox token.
   The gateway authenticates, registers a transport with the broker, and stores the reported
   capability matrix and client metadata.
3. **Attach agent** — an MCP client POSTs `initialize` with its bearer token. The connection is
   recorded for the dashboard.
4. **Operate** — tool calls flow through `invokeTool`, which gates, validates, rate-limits, then
   either answers locally or dispatches a command and awaits a result.
5. **End** — expiry, owner termination, or credential revocation. Pending commands fail with a
   structured error, the socket is closed, and the record is swept shortly after.

## Command flow

```
tools/call
   │
   ▼
invokeTool ── availability gate (feature · capability · privilege · connection)
   │
   ├─ local tool  ──▶ answered from session state
   │
   └─ remote tool ──▶ Zod validation ──▶ rate limit ──▶ broker.dispatch
                                                            │
                                          registers pending command + timer
                                                            │
                                                     sends `command` frame
                                                            │
                                     ┌──────────────────────┴───────────────────┐
                                     ▼                                          ▼
                             `result` frame                              timeout fires
                                     │                                          │
                    resolveResult (session-scoped)                  `cancel_command` sent
                                     │                                          │
                                     └──────────────▶ normalise + audit ◀───────┘
```

`resolveResult` requires the answering session to match the pending command's session. That single
check is what makes cross-session result injection impossible, and it is covered by an integration
test that actively attempts the attack.

## Why in-memory

Nothing in a session is worth persisting past a restart: credentials are ephemeral, the Roblox
connection cannot survive a redeploy anyway, and the audit trail is a debugging aid rather than a
record of account. Holding state in memory removes a data-at-rest surface and a whole class of
migration and cleanup work.

The cost is stated plainly everywhere it matters: **one instance only, and a restart ends every
session.** Scaling out would require a shared broker (Redis pub/sub for command routing plus a
shared session store), which is a deliberate future step rather than an oversight.

## Extension points

- **Ownership verification** — the natural insertion point is `handleHello` in the gateway, after
  credential authentication and before `attachRoblox`, using the reported `placeId` / `universeId`.
  Not implemented.
- **Multi-instance routing** — replace `SessionBroker`'s in-process `transports` map with a shared
  channel, keyed by session id.
- **Durable audit** — `AuditLog.record` is the single write point.
