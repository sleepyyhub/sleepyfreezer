# Clovyre protocols

Two protocols: the Roblox WebSocket protocol (Clovyre's own) and MCP over Streamable HTTP.

---

## 1. Roblox WebSocket protocol

**Endpoint:** `wss://<deployment>/ws/roblox`
**Encoding:** UTF-8 JSON text frames. Binary frames are rejected.
**Version:** every frame carries `"protocolVersion": 1`.

### Authentication

Executor WebSocket APIs cannot set request headers, so the credential travels in the first
application-level frame instead of the HTTP upgrade. Consequences:

- Only `hello` is accepted before authentication.
- A connection that has not authenticated within **10 seconds** is closed with code `4001`.
- A second authenticated connection for the same session replaces the first (`4004`), so two bridges
  never answer the same command.

### Client → server

#### `hello`

```json
{
  "protocolVersion": 1,
  "type": "hello",
  "sessionId": "cs_XXXXXXXXXXXXXXXXXXXX",
  "token": "crx_...",
  "capabilities": { "websocket": true, "decompile": false },
  "metadata": {
    "placeId": 1818,
    "universeId": 9090,
    "jobId": "…",
    "gameName": "…",
    "localPlayer": { "name": "…", "displayName": "…", "userId": 1, "accountAge": 365 },
    "executor": "…"
  },
  "bridgeVersion": "0.1.0"
}
```

#### `heartbeat`

`{ "protocolVersion": 1, "type": "heartbeat", "sentAt": 1737000000 }` — every 15 s. The server drops
a client that has been silent for three intervals (`4008`).

#### `result`

```json
{
  "protocolVersion": 1,
  "type": "result",
  "id": "cmd_…",
  "ok": true,
  "result": {},
  "durationMs": 12
}
```

```json
{
  "protocolVersion": 1,
  "type": "result",
  "id": "cmd_…",
  "ok": false,
  "error": { "code": "INSTANCE_NOT_FOUND", "message": "The requested instance is unavailable." }
}
```

Results for unknown or already-settled ids are discarded and recorded as a protocol violation.

#### `event`, `log`, `capabilities_update`, `goodbye`

- `event` — `{ "event": "name", "data": {} }`, recorded in the audit trail.
- `log` — `{ "level": "info", "message": "…" }`, one of `trace|debug|info|warn|error`.
- `capabilities_update` — replaces the capability matrix, re-gating tools live.
- `goodbye` — `{ "reason": "…" }`, a clean shutdown signal.

### Server → client

| Type              | Payload                                                                          | Meaning                                  |
| ----------------- | -------------------------------------------------------------------------------- | ---------------------------------------- |
| `hello_ack`       | `sessionId`, `heartbeatIntervalMs`, `maxPayloadBytes`, `expiresAt`, `serverTime` | Authenticated                            |
| `command`         | `id`, `tool`, `arguments`, `timeoutMs`                                           | Run this tool                            |
| `cancel_command`  | `id`                                                                             | Stop; the server stopped waiting         |
| `session_revoked` | `reason`                                                                         | Session terminated or credential revoked |
| `session_expired` | `expiredAt`                                                                      | Session lifetime elapsed                 |
| `heartbeat_ack`   | `serverTime`                                                                     | Liveness confirmed                       |
| `error`           | `code`, `message`                                                                | Frame rejected                           |

```json
{
  "protocolVersion": 1,
  "type": "command",
  "id": "cmd_unique_id",
  "tool": "clovyre_inspect_instance",
  "arguments": { "displayPath": "ReplicatedStorage.Controllers" },
  "timeoutMs": 15000
}
```

The bridge strips the `clovyre_` prefix to find its handler.

### Close codes

| Code   | Meaning                                                   |
| ------ | --------------------------------------------------------- |
| `4001` | Not authenticated (bad credential, or no `hello` in time) |
| `4003` | Session expired, terminated, or credential revoked        |
| `4004` | Replaced by a newer connection for the same session       |
| `4008` | Heartbeat timeout                                         |
| `4404` | Session no longer exists                                  |
| `1009` | Frame exceeded the payload limit                          |

### Error codes

`INVALID_MESSAGE`, `PROTOCOL_VERSION_MISMATCH`, `PAYLOAD_TOO_LARGE`, `UNAUTHORIZED`,
`SESSION_NOT_FOUND`, `SESSION_EXPIRED`, `SESSION_REVOKED`, `CLIENT_NOT_CONNECTED`,
`COMMAND_TIMEOUT`, `COMMAND_CANCELLED`, `COMMAND_NOT_FOUND`, `CAPABILITY_UNAVAILABLE`,
`PRIVILEGE_REQUIRED`, `RATE_LIMITED`, `INSTANCE_NOT_FOUND`, `PROPERTY_NOT_ALLOWED`,
`INVALID_ARGUMENTS`, `TOO_MANY_CONNECTIONS`, `INTERNAL_ERROR`.

---

## 2. Instance addressing

Roblox names may contain dots, so a dot-joined string is ambiguous. The wire format is an ordered
list of segments:

```json
{
  "segments": [
    { "name": "ReplicatedStorage", "className": "ReplicatedStorage" },
    { "name": "Controllers", "className": "Folder" },
    { "name": "Combat.Controller", "className": "ModuleScript" }
  ]
}
```

Tools accept any one of:

- `ref` — a session-scoped handle like `ref_12`. Cheapest, survives renames, invalidated when the
  instance is destroyed or streamed out.
- `path` — the structured form above.
- `displayPath` — a convenience string where a literal dot inside a name is escaped as `\.`, e.g.
  `ReplicatedStorage.Controllers.Combat\.Controller`.

Paths are never resolved with `loadstring`. Services resolve through `GetService`; everything else
through `FindFirstChild`.

---

## 3. Value serialisation

Non-primitive values carry a `__t` tag so the type survives JSON:

```json
{ "__t": "Vector3", "x": 1, "y": 2, "z": 3 }
{ "__t": "EnumItem", "enumType": "Material", "name": "Plastic", "value": 256 }
{ "__t": "Instance", "ref": "ref_3", "name": "Part", "className": "Part", "displayPath": "Workspace.Part" }
```

Supported tags: `Vector2`, `Vector3`, `CFrame`, `Color3`, `BrickColor`, `UDim`, `UDim2`, `Rect`,
`NumberRange`, `NumberSequence`, `ColorSequence`, `Enum`, `EnumItem`, `Instance`, `Ray`, `Region3`,
`TweenInfo`, `DateTime`, `Buffer`, `Axes`, `Faces`, `PhysicalProperties`, `Font`.

Three control tags: `Truncated` (with a `reason`), `Cycle`, and `Unsupported` (with a `reason`).

Limits are applied on the client and **re-applied on the server**, because the client is untrusted
input: depth 8, 200 items per container, 8 KiB per string, 5000 nodes total, cycle detection, and a
payload ceiling per frame. Non-finite numbers become `Unsupported` rather than invalid JSON.

---

## 4. MCP over Streamable HTTP

**Endpoints:** two equivalent forms.

```
POST https://<deployment>/api/mcp/<sessionId>            Authorization: Bearer <MCP token>
POST https://<deployment>/api/mcp/<sessionId>/<MCP token>
```

**Auth:** `Authorization: Bearer <session MCP token>`, or `X-Clovyre-Token`, or the token as the
final path segment. A token in the path wins, because a client using that URL form cannot send a
header at all.

The path form exists for connector UIs that accept only a URL — claude.ai's custom connector is the
motivating case. The credential is then visible to proxy and platform access logs, which is an
accepted trade-off for a session-scoped credential that expires with its session and can be
regenerated or revoked at will. Both forms authenticate against the addressed session's own digest,
so neither can drive a different session.
**Response:** `application/json`. Clovyre has no server-initiated messages, so it never opens an SSE
stream and `GET` returns `405` with an explanation.

### Methods

| Method                           | Behaviour                                                                                          |
| -------------------------------- | -------------------------------------------------------------------------------------------------- |
| `initialize`                     | Negotiates `2025-06-18`, `2025-03-26` or `2024-11-05`; returns `serverInfo` and scope instructions |
| `ping`                           | `{}`                                                                                               |
| `tools/list`                     | Tools the session may currently see                                                                |
| `tools/call`                     | Runs a tool                                                                                        |
| `resources/list`, `prompts/list` | Empty; Clovyre exposes neither                                                                     |
| `notifications/*`                | Accepted, answered with `202` and no body                                                          |

### Tool results

Success:

```json
{
  "content": [{ "type": "text", "text": "…" }],
  "structuredContent": { "commandId": "cmd_…", "durationMs": 12, "truncated": false, "data": {} },
  "isError": false
}
```

Failure is a **successful JSON-RPC response** with `isError: true`, so the agent can reason about it
rather than treating it as a transport fault:

```json
{
  "content": [{ "type": "text", "text": "…" }],
  "structuredContent": { "code": "PRIVILEGE_REQUIRED", "message": "…" },
  "isError": true
}
```

Protocol-level faults use JSON-RPC error codes: `-32700` parse, `-32600` invalid request, `-32601`
method not found, `-32602` invalid params, `-32603` internal.

### Visibility rules

- Tools blocked only because the Roblox client is momentarily disconnected **stay listed**, with the
  reason appended to the description, and fail with `CLIENT_NOT_CONNECTED`.
- Tools requiring an ungranted privilege are **hidden entirely**, so an agent cannot attempt them.
- Tools requiring an absent executor capability stay listed and fail with `CAPABILITY_UNAVAILABLE`.

### Batching

Arrays of up to 32 messages are accepted. Batches larger than that are rejected with `-32600`.
