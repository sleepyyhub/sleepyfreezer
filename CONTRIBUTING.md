# Contributing to Clovyre MCP

## Getting set up

Requires Node 20 or newer.

```bash
npm ci
cp .env.example .env.local     # fill in SESSION_SECRET and TOKEN_HASH_SECRET
npm run dev
```

## Before you open a pull request

All four must pass:

```bash
npm run lint
npm run typecheck
npm test
npm run build
```

Browser tests need a production build first:

```bash
npm run build && npm run test:e2e
```

## House rules

**Honesty in the interface.** Clovyre's value depends on not overstating what it can reach. Never
label decompiled output as original source, never describe the execution environment as sandboxed,
and never show a connection status that is not backed by an actual connection. If a limitation is
real, say so in the UI and the docs.

**Privileged by exception.** Anything that writes to the client or executes code must be off by
default, require an explicit owner grant, expire on its own, and be audited. An MCP client must
never be able to grant itself anything.

**Validate at the boundary.** Every WebSocket frame and every tool argument goes through Zod.
Everything returned by the Roblox client is untrusted input and is re-normalised server-side with
depth, item and size limits.

**Bound everything.** New tools need explicit result caps, a timeout, and a payload ceiling. An
unbounded traversal is a bug even when it works on a small place.

**No secrets in output.** Anything that reaches a log, an audit event or an API response goes
through `src/lib/security/redact.ts` first.

**No external assets.** No image files, no CDN fonts, no third-party scripts. The mark and wordmark
are CSS and inline SVG, and the CSP forbids external origins.

**Strict TypeScript.** No `any` unless it is genuinely unavoidable and documented in a comment.
Never suppress a type error to make a build pass.

## Adding a tool

1. Define it in `src/lib/tools/registry.ts` with a Zod schema, a description that states its limits,
   a timeout, and any `requiresCapability` / `requiresPrivilege`.
2. Implement the handler in `roblox/client.lua` under `handlers.<name>` — the bridge strips the
   `clovyre_` prefix.
3. Return serialised values through `serialize()` so limits and cycle detection apply.
4. Add tests: a schema test in `tests/unit/tools.test.ts`, and a routing test in
   `tests/integration/gateway.test.ts` using the mock client.
5. Update the README tool list and `/docs`.

## Editing the safe-property registry

`src/lib/tools/safe-properties.ts` and the `SAFE_PROPERTIES` table in `roblox/client.lua` mirror
each other. Change both together. Properties must be cheap to read and must not pull in asset
payloads.

## Commit style

Short imperative subject, body explaining why when it is not obvious. Keep a change focused; a
protocol change and a UI change belong in separate commits.
