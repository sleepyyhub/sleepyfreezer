# Verdant Reach — playable vertical slice

A browser 3D low-poly action-RPG. This is the prototype scoped in
[`docs/game-design/README.md`](../docs/game-design/README.md) §10.1: one zone,
two enemy archetypes, one two-phase boss, full combat, progression, loot and
saving.

```bash
npm install
npm run dev          # http://localhost:5173
npm test             # 53 unit tests, ~700ms
npm run build        # typecheck + production bundle
```

## Controls

| | |
|---|---|
| `WASD` | Move (camera-relative) |
| Mouse | Orbit camera · scroll to zoom |
| Left click | Light attack (3-hit chain) |
| Right click / `F` | Heavy attack |
| `Space` | Dodge roll — i-frames 0.10s–0.42s |
| `Q` | Surge (8s cooldown) |
| `E` | Interact / open chest |
| `T` | Cycle lock-on |
| `I` `C` `H` | Inventory · Character · Help |

The boss is south of the spawn point. Walk about 50m toward `-Z`.

## Architecture

The one rule that shapes everything: **nothing under `src/sim/` imports
`three`.** Damage, AI, loot, and progression are pure and headless, which is
what makes them testable in milliseconds and what makes a future
server-authoritative validator a port rather than a rewrite.

```
src/
├── core/      Game loop, input, event bus, quality tiers
├── sim/       Pure simulation — no three.js below this line
│   ├── formulas.ts    damage, xp, stat curves
│   ├── World.ts       fixed-step step(), combat, enemy FSM
│   ├── loot.ts        weighted tables, pity, affixes
│   ├── progression.ts the single gate predicate
│   └── terrain.ts     heightfield shared by sim and renderer
├── render/    three.js: materials, zone, rigs, camera, VFX
├── content/   All game data. Designers edit here, not code.
├── ui/        React HUD/panels over the canvas + zustand store
└── net/       Save adapter (local now, Supabase-shaped interface)
```

### Notable implementation choices

**Fixed 60 Hz sim with render interpolation.** Combat timings are frame-rate
independent. The frame delta is clamped at 250ms — an unclamped accumulator
runs hundreds of steps after a backgrounded tab and freezes the page.

**No physics engine.** Kinematic capsule, axis-separated sliding, slope
limiting, sphere-overlap hitboxes. Rapier's 400KB buys dynamics that make an
action-RPG character feel shoveable. The terrain heightfield is a pure
function both layers call, so the collision surface and the visible mesh
cannot disagree.

**Input buffering (0.2s) and coyote i-frames (0.05s).** Nobody notices these
exist; everybody notices when they are missing. They are the difference
between combat people call crisp and combat people call janky.

**Everything repeated is an `InstancedMesh`.** A zone with 280 props is a
handful of draw calls. Materials are cached per colour so the whole world
shares a few shader programs.

**HUD updates at 15 Hz, not 60.** Health numbers changing 15 times a second
are indistinguishable to a human and cost a quarter of the React work.

**Procedural placeholder art.** No GLBs yet. `buildPlayerRig` /
`buildEnemyRig` return a `CharacterRig` — that interface is the contract the
animator codes against, so swapping in real art replaces the factory and
nothing else.

**World-space UI opts out of tone mapping and fog.** Health bars and
telegraph decals are UI that happens to live in the scene; ACES and green fog
turn them into unreadable maroon. Telegraph colour is a fixed game-wide
language (red = dodge), so it must not drift per world.

## Adding content

Everything below is data. Adding World 2 means adding a file shaped like
`content/worlds/w1_verdant_reach.ts` and registering its id in
`content/index.ts` — no system changes.

- **Enemy** → `content/enemies.ts`. `reactionDelayS` is the most important
  knob in the file: instant reactions read as aimbots, 0.2–0.4s reads as
  intelligence and creates the openings that make combat legible.
- **Item** → `content/items.ts`
- **Drop table** → `content/droptables.ts`. Include an explicit `null` entry
  so every real item's rate reads straight off the weights.
- **Gate** → any `Condition`; they all route through `isSatisfied()`.

`tests/content.test.ts` enforces the invariants a type system can't: anchors
inside the reachable area, no anchor in water or on a cliff, every referenced
id exists, boss phases ordered and reaching zero, every enemy attack
telegraphed. It exists because an authored coordinate outside the playable
disc made the boss unreachable and nothing caught it.

## Verified

- 53 unit tests pass; `tsc --noEmit` clean.
- 194 KB gzipped total (73 KB app + 120 KB three), against a 400 KB budget.
- Headless playthrough via `node smoke.mjs` — boots, fights, kills, levels,
  drops loot, triggers the boss, dies, persists the save, zero console errors.

## Known gaps

- **Save is local-only.** `SaveAdapter` is the seam; the Supabase schema is in
  the design doc but not wired.
- **No audio.** Howler is speced, not integrated.
- **One zone.** No world map or zone transitions, so the exit-gate machinery
  is tested but not exercised in play.
- **Boss is the mid-boss only.** Grand Elder Kaanu is designed, not built.
- **No affix pool differentiation by world** — one shared pool until World 2
  exists to differentiate from.
- **Placeholder art**, per above.
