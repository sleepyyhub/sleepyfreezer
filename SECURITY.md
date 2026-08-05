# Security

## Reporting a vulnerability

Open a **private security advisory** on the repository rather than a public issue. Include what you
found, how to reproduce it, and what an attacker gains. You will get an acknowledgement, and fixes
for confirmed issues land on the default branch with the advisory published afterwards.

Please do not test against a deployment you do not control, and never use a finding against an
experience you are not authorised to test.

## Threat model

Clovyre relays inspection commands between three parties that do not trust each other equally:

| Party                   | Trust                            | Credential                                   |
| ----------------------- | -------------------------------- | -------------------------------------------- |
| Session owner (browser) | Highest — configures the session | `httpOnly` owner cookie + CSRF token         |
| Roblox client           | Untrusted input, trusted origin  | Roblox token, presented in the `hello` frame |
| MCP agent               | Least — may be autonomous        | Bearer MCP token                             |

The important asymmetry: **an MCP agent must never be able to escalate its own privileges.** Only
the browser owner can enable Luau execution or mutation tools, and there is no API path that lets an
agent request it.

## Controls

**Credentials**

- Four independent per-session credentials, each 256 bits of entropy from `crypto.randomBytes`.
- Only HMAC-SHA256 digests are stored; plaintext is shown once, at creation.
- Comparisons are constant-time (`timingSafeEqual`).
- The public session id is an address, never an authenticator.
- Each credential can be revoked independently; revoking the Roblox credential also drops the live
  socket rather than leaving an already-authenticated connection alive.

**Session isolation**

- A credential is only ever checked against the session named in the request.
- The broker resolves a pending command only when the answering transport belongs to the same
  session, so a result from session A cannot satisfy a command on session B.
- Results for unknown or already-settled command ids are discarded and audited.

**Browser routes**

- Owner routes require the `httpOnly` cookie, a same-origin request, and a double-submit CSRF token
  matching both the cookie and the value bound to the session.

**Transport**

- HTTPS and WSS only in production; HSTS set.
- Executor WebSocket APIs cannot set headers, so authentication happens in the first application
  frame. Nothing but `hello` is accepted before that, and a connection that does not authenticate
  within 10 seconds is dropped.

**Input handling**

- Every WebSocket frame and every tool argument is validated with Zod.
- Unknown message types, oversized payloads and binary frames are rejected.
- Values returned by the client are re-normalised server-side with depth, item, string and node
  limits, plus cycle detection.

**Abuse limits**

- Per-address limits on session creation and WebSocket handshakes.
- Per-session limits on MCP requests, tool calls and Luau execution.
- Command timeouts, a concurrency cap per session, and payload ceilings in both directions.

**Secrets in output**

- A redaction layer scrubs credential-shaped values (`crx_`, `cmc_`, `cow_`, `rnd_`, GitHub tokens,
  bearer headers) and sensitive header names from logs, audit events and API responses.
- No `NEXT_PUBLIC_*` variables exist, so no secret can reach the browser bundle.
- Deployment credentials are never read by the application.

**Headers**

- CSP with no external origins, `X-Frame-Options: DENY`, `nosniff`, a restrictive `Permissions-Policy`
  and `Cross-Origin-Opener-Policy: same-origin`.

## Known limitations

These are accepted, documented properties of the prototype:

1. **No ownership verification.** Clovyre does not verify that a session owner controls the
   experience being inspected. The architecture has a hook for it; the check is not implemented.
2. **`clovyre_execute_luau` is not sandboxed.** It runs in the executor's environment. The
   "executor globals" toggle masks well-known globals via `setfenv` but a determined chunk can
   generally reach the real environment. Clovyre says so in the interface and the documentation
   rather than claiming isolation it does not have.
3. **In-memory state.** Rate-limit buckets and sessions are per-process and reset on restart.
   Running more than one instance would break both session routing and rate limiting.
4. **Trust in the executor.** The bridge script runs inside an executor the user chose. Clovyre
   cannot attest to what that executor does with the data.
5. **Agent trust.** An MCP agent with a valid token can call every non-privileged tool. Revoke the
   MCP credential to cut it off.

## Operational guidance

- Set `SESSION_SECRET` and `TOKEN_HASH_SECRET` explicitly in production; otherwise ephemeral secrets
  are generated at boot and every session dies on restart.
- Keep `numInstances: 1` unless a shared session broker is added.
- Use `ENABLE_EXECUTE_LUAU_FEATURE=false` and `ENABLE_MUTATION_TOOLS_FEATURE=false` to disable the
  privileged families deployment-wide, regardless of any owner grant.
