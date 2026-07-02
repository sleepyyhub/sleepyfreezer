# 🛡️ Sleepy Royale

A 2D battle-royale game inspired by Fortnite, built for **touch play in landscape** —
iPads first, but any phone works too: small screens automatically zoom the camera out
and switch to a compact HUD (media query at 500px height), so every iPhone/Android
model gets full-size gameplay with thumb-sized controls.
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
- **Combat** — 10 weapons across 6 rarity tiers (Common → Mythic), each with a tough
  name and distinct stats: Rustfang (pistol), Hornet (SMG), Gravedigger (shotgun), plus
  7 specials — Meatgrinder (minigun), Hydra (3-round burst), Dragon's Breath (flamer),
  Widowmaker (railgun), Deadeye (sniper), Phantom Lance (pierces through players) and
  Doomsday (explosive splash damage). Muzzle flash, per-weapon tracers, hit markers,
  damage numbers, kill feed, screen shake.
- **Ammunition** — three ammo types (Light / Shell / Energy) consumed per shot, shown
  next to your weapon in the HUD; refill from ammo packs in chests and NPC drops.
  NPCs never run dry.
- **Auto-aim** — within ~320px and clear line of sight, your aim locks on (red reticle);
  dragging the aim zone overrides it.
- **Ruined buildings** — 14 seeded run-down structures on a 5600px island, with
  destructible cracked walls, door gaps, collapsed chunks, debris, and a broken roof
  that lifts when you walk inside.
- **Guardians, THE WARDEN & special weapons** — each building is defended by a "Ruin
  Guardian" (180 hp, red aura) armed with a real gun; guardians never leave their house
  and shoot slow and sloppy (they're loot piñatas, not sharpshooters). Each drops one of
  the 7 special weapons plus energy ammo. Kill all 14 and **THE WARDEN** (800 hp boss)
  awakens at the map center, hunts players across the whole map, and drops another
  special + supplies. In multiplayer the party host's client simulates all NPCs and
  syncs them to everyone.
- **Chests & ground loot** — 39 chests in four tiers (26 Normal, 7 Epic, 4 Legendary,
  2 Mythic), color-coded with matching glows and minimap dots. Opening a chest spills
  its loot onto the ground as rarity-colored pickups — stand on an item to see its name,
  rarity and stats on an item card, then take only what you want.
- **Weapon panel** — standard-shooter HUD bottom-right: weapon icon, name and rarity
  with a rarity-colored bar, plus a big ammo counter that turns red when dry.
- **Deployable shield** — a dedicated 🛡 button raises a barrier in front of you for
  20 wood (loot wood from chests). It soaks 2 enemy bullets (cracks after the first),
  then shatters; shots from behind go right through it.
- **Practice range** — a fenced corner (top-left) with four bare training figures:
  shoot them to warm up, they fall over and get back up after 3 seconds.
- **Presentation** — textured grass, drop shadows, cinematic vignette, red hurt flash,
  and a live minimap (buildings, chests, storm circle, you, teammates, guardians).
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

## Putting it online

The game is two parts: a static page (`index.html`) and a small Node WebSocket server
(`server.js`). Anything that can run Node can host the full multiplayer game.

**Google Cloud Run (the "Google" way, free tier available):**
1. Create a project at https://console.cloud.google.com and install the `gcloud` CLI.
2. From this repo folder run:
   ```bash
   gcloud run deploy sleepy-royale --source . --region europe-west3 --allow-unauthenticated
   ```
   Cloud Run detects `package.json`, runs `npm start`, and gives you a public
   `https://…run.app` URL. The server already reads `process.env.PORT` and the client
   automatically upgrades to `wss://` on HTTPS, so WebSockets work out of the box.
3. Open the URL on any iPad — parties, lobbies and matches all work over the internet.

**Free alternatives that also run the Node server:** Render.com, Railway.app, Fly.io,
or Glitch — connect the GitHub repo and set the start command to `npm start`.

**GitHub Pages / Firebase Hosting (static-only):** these serve `index.html` for free and
solo-vs-bots works perfectly, but they cannot run `server.js`, so party multiplayer
would need the WebSocket server hosted elsewhere.

**Getting found on Google Search:** put the game on a public URL first, then add the
site at https://search.google.com/search-console and request indexing. Publishing on
Google Play would require wrapping the page in a TWA (e.g. with Bubblewrap) — a separate
project.

## Extending

Tuning lives in one `CFG` object and a `WEAPONS` table at the top of the script in
`index.html`. Each system is a numbered, commented section (input, building, combat,
bots, storm, rendering) so you can modify one without touching the others.
