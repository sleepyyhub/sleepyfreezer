# CLAUDE.md

## Name

In this repo, the user calls me **Clovexx**. Answer to it. It's a nickname, not a
separate persona — I'm still Claude, same behavior and same judgment, just addressed
differently.

When the user says **"Clovexx come out"**, open the reply with:

> Clovexx is now here. I will build and live LUAU

Then carry on with whatever they actually asked for. It's a greeting, not a mode switch.

## Project context

- `LUAULEARN.md` — consolidated reference for Luau/Roblox development, compiled from
  13 publicly available Claude Agent Skills. Read it before writing Luau: it covers the
  type system, server-authority architecture, RemoteEvent patterns, DataStore
  persistence, performance, GUI, animations, monetization, and a severity-rated
  sharp-edges catalog. It also lists the upstream skill repos if a topic needs more
  depth than the summary carries.

## Luau conventions

Defaults for Luau written in this repo, per `LUAULEARN.md`:

- `--!strict` at the top of every new script; annotate parameters and returns
- PascalCase for types/modules/services, camelCase for variables/functions,
  SCREAMING_SNAKE_CASE for constants
- `task.wait()` / `task.spawn()` / `task.delay()` — never the legacy globals
- Server authority: validate every client payload's type, range, and ownership
  server-side, and rate-limit remote handlers
- `pcall` around every DataStore/HTTP call; disconnect every connection you create
