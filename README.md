# 🛡️ Sleepy Royale

A 2D battle-royale game inspired by Fortnite, built for **iPad landscape touch play**.
The whole client is a single `index.html` (canvas rendering, procedural shapes, zero
external assets); `server.js` is a tiny Node.js + `ws` server for parties, lobbies and
real-time sync.

## Quick start

**Solo (no server needed):** open `index.html` in Safari on an iPad (or any browser)
and tap **PLAY SOLO** — you fight 7 bots.

**Multiplayer:**
```bash
npm install
npm start          # serves the game + WebSocket on http://<your-ip>:8080
```
Open `http://<your-ip>:8080` on each iPad on the same network. One player taps
**CREATE PARTY**, shares the 4-letter code, everyone else taps **JOIN**.

## Controls (two-handed landscape)

| Zone | Control |
|---|---|
| Left ~45% of screen | Virtual joystick — touch anywhere, drag to walk (joystick appears under your thumb) |
| Right side drag | Aim — a dashed line + reticle shows your aim direction |
| 🔥 FIRE button (bottom-right) | Hold to shoot the current weapon |
| 🔨 BUILD button | Toggles build mode: pick wall/ramp/floor + wood/brick/metal, then **tap a grid cell** near your character to place |
| 📦 OPEN CHEST | Appears automatically when you walk near an unopened chest |

All buttons are ≥ 56 px (above the 44 pt minimum); everything uses
`touchstart`/`touchmove`/`touchend` (mouse events exist only as a desktop debug fallback).

## Systems overview (all in `index.html`, section-numbered comments)

- **Movement & collision** — walls and rocks block, sliding along surfaces; floors give a
  small speed boost, ramps can be vaulted slowly.
- **Combat** — pistol / SMG / shotgun with distinct damage, fire rate, spread and range;
  muzzle flash, bullet trails, hit markers, floating damage numbers, kill feed.
- **Chests** — 14 per map, seeded loot (weapons, medkits, materials) with pop-open animation.
- **Building** — grid-based wall/ramp/floor in 3 materials with per-piece HP; pieces are
  destructible and cost 10 material each (resource counters in the top-right HUD).
- **Storm** — shrinking safe circle in 4 phases with escalating damage per second, drawn as
  a purple overlay; runs deterministically from the match seed so clients never desync.
- **Bots** — simple wander/fight/flee-the-storm AI for solo play.
- **Customization** — eyes × hair × outfit presets drawn procedurally; synced live to the
  party lobby and visible in-match. Saved to `localStorage`.

## Multiplayer architecture

One Node process serves the HTML **and** the WebSocket on the same port, so the client
just connects to `location.host`. Messages are small JSON packets `{ t: <type>, ... }`.

- **Server-authoritative lobby:** party codes (4 chars, no ambiguous letters), roster,
  host migration, game mode (Solos / 2v2 / 4v4), and team assignment (host taps a player
  row in the lobby to flip them between Team A and Team B).
- **Relay-based match:** each client owns its own player and broadcasts
  position/aim/hp at 15 Hz; shots and builds are relayed and re-simulated by every peer;
  damage is routed only to the victim's client, which applies it and reports back via its
  next state packet. Map layout, chest loot and storm timing all derive from one shared
  seed sent in `match_start`, so no world data crosses the wire.

This is intentionally trust-the-client simple — perfect for playing with friends, easy to
read and extend. To harden it later, move bullet simulation and hp onto the server and
have clients send inputs instead of state.

## Extending

Tuning lives in one `CFG` object and a `WEAPONS` table at the top of the script in
`index.html`. Each system is a numbered, commented section (input, building, combat,
bots, storm, rendering) so you can modify one without touching the others.
