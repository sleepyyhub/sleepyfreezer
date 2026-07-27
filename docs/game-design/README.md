# Low-Poly Anime RPG — Technical & Game Design Document

A browser-based 3D PvE action-RPG with flat-shaded low-poly art and data-driven
themed worlds. World 1 is an alien planet in the Namek mold; World 2 is a
medieval magic-knight kingdom in the Clover mold.

> **IP note up front, because it affects architecture, not just legal risk:**
> ship the worlds as *original* settings that borrow the genre grammar, not the
> trademarks. "Planet Namek" → **Verdant Reach**; "Clover Kingdom" → **Trefoil
> Marches**. Every proper noun in this document lives in a JSON world config
> (§4.3), so renaming a world is a data edit, never a code edit. Design for the
> homage; name for yourself.

---

## Table of contents

1. [Tech stack & architecture](#1-tech-stack--architecture)
2. [Art direction](#2-art-direction)
3. [Core gameplay loop](#3-core-gameplay-loop)
4. [World progression structure](#4-world-progression-structure)
5. [Combat system](#5-combat-system)
6. [Progression systems](#6-progression-systems)
7. [Loot & drop system](#7-loot--drop-system)
8. [Boss design](#8-boss-design)
9. [UI/UX](#9-uiux)
10. [MVP scope](#10-mvp-scope)
11. [Risk register](#11-risk-register--tradeoffs-summary)

---

## 1. Tech stack & architecture

### 1.1 Three.js vs Babylon.js — recommendation

**Use Three.js.** For this specific scope the deciding factors:

| Factor | Three.js | Babylon.js | Matters here? |
|---|---|---|---|
| Bundle size (min+gzip, tree-shaken) | ~150–170 KB for a scene like this | ~700 KB–1.4 MB core+loaders | **Yes.** First-load budget is the single biggest browser-game conversion killer. |
| Flat-shaded low-poly rendering | Trivial — `MeshLambertMaterial` / `MeshToonMaterial`, `flatShading: true` | Equally capable, heavier material system | Tie in output, Three is less code |
| Batteries included (physics, GUI, inspector, animation blending, scene serialization) | You assemble it (Rapier, your own DOM UI) | Built in, coherent | Babylon wins — but you'd replace half of it anyway (see below) |
| Rendering perf at 60fps with 40k–120k tris | Equivalent; both bottleneck on draw calls, not the engine | Equivalent | Tie |
| Ecosystem for stylized/toon shading | Much larger — most low-poly/toon shader references are Three | Smaller | Three wins |
| WebGPU path | `WebGPURenderer` maturing, TSL node materials | More mature WebGPU | Babylon wins, but WebGL2 is the correct target for 2–3 years |

Babylon's real advantage is being a *game engine* — its physics wrappers, GUI
system, and animation state machine are genuinely better than rolling your own.
But for an action-RPG with kinematic character control and no ragdolls, you do
not want a physics engine driving your player anyway (§1.5), and you should
render UI in **DOM/React, not in-canvas** (§9.1) — which deletes Babylon's GUI
advantage outright. What remains is a 4–8× larger bundle for features you
won't use.

**Choose Babylon instead if** you commit to full rigid-body physics-driven
combat (knockback, destructible props, throwables with collisions), or if the
team already knows it. Engine familiarity beats a 500 KB bundle delta.

**Do not use react-three-fiber for the game simulation.** Use it, if you like,
for the *out-of-combat* scenes (character select, world map). Reconciling a
React tree at 60fps for hundreds of entities is fighting the framework. Keep the
game loop imperative and let React own the HUD only.

### 1.2 Full stack

```
Rendering      three (WebGL2) + custom toon/flat materials
Bundler        Vite (esbuild dev, rollup prod, native code-splitting)
Language       TypeScript, strict mode
State          Zustand (vanilla store, no React dependency in the sim)
UI             React + Zustand selectors, DOM overlay above the canvas
Physics        none (custom kinematic controller + spatial hash) — see §1.5
Audio          Howler.js (sprite-sheeted SFX, one HTTP request)
Assets         glTF 2.0 + Draco + KTX2/Basis textures
Tweening       hand-rolled (~80 lines) or @tweenjs/tween.js
Save backend   Supabase (Postgres + Auth + Edge Functions) — see §1.6
Analytics      PostHog or self-hosted Umami; event funnel per zone
Hosting        Cloudflare Pages (static) + Supabase (data)
Test           Vitest for sim logic (pure functions), Playwright for smoke
```

### 1.3 Project structure

The organizing rule: **the simulation must be runnable headlessly.** Nothing in
`src/sim/` may import `three`. This makes damage formulas, drop tables, AI state
machines, and progression unit-testable in milliseconds, and later makes an
authoritative server possible without a rewrite.

```
src/
├── main.ts                     # bootstrap, canvas, render loop
├── core/
│   ├── Game.ts                 # owns loop; fixed-step sim + interpolated render
│   ├── Clock.ts                # accumulator, 60 Hz sim tick
│   ├── EventBus.ts             # typed pub/sub (sim → UI, sim → VFX)
│   ├── SceneManager.ts         # zone lifecycle: load / activate / dispose
│   ├── AssetRegistry.ts        # ref-counted GLTF/texture cache
│   └── Input.ts                # keyboard/mouse/gamepad → intent struct
├── sim/                        # ⚠ NO three.js imports below this line
│   ├── ecs/
│   │   ├── World.ts            # entity ids, component arrays, systems list
│   │   └── components.ts       # Transform, Health, Stats, Hitbox, AIState…
│   ├── systems/
│   │   ├── MovementSystem.ts
│   │   ├── CombatSystem.ts     # attack windows, hit resolution
│   │   ├── HitboxSystem.ts     # spatial hash broadphase
│   │   ├── AISystem.ts         # per-archetype behavior FSM
│   │   ├── StatusSystem.ts     # burn/slow/stagger stacks
│   │   └── LootSystem.ts
│   ├── formulas.ts             # damage, xp, stat curves — PURE
│   └── rng.ts                  # seeded mulberry32; loot seeds are reproducible
├── render/
│   ├── Renderer.ts             # WebGLRenderer, tone mapping, post FX
│   ├── CameraRig.ts            # third-person orbit + collision spring
│   ├── materials/toon.ts       # shared ramp material factory
│   ├── views/                  # ECS entity ↔ three.Object3D binding
│   ├── vfx/                    # hit sparks, slash trails, boss telegraphs
│   └── env/                    # skybox, fog, water, instanced foliage
├── content/                    # 100% data. Designers edit here, not code.
│   ├── worlds/
│   │   ├── w1_verdant_reach.json
│   │   └── w2_trefoil_marches.json
│   ├── enemies/*.json
│   ├── items/*.json
│   ├── droptables/*.json
│   ├── abilities/*.json
│   └── schema/*.schema.json    # ajv-validated in CI
├── ui/
│   ├── App.tsx  HUD/  Inventory/  CharacterSheet/  WorldMap/  Dialogue/
│   └── store/           # zustand slices: player, inventory, ui, progression
├── net/
│   ├── save.ts                 # debounced autosave, offline queue
│   └── supabase.ts
└── shared/types.ts             # types shared by sim, ui, content schemas
```

### 1.4 Loop architecture

Fixed-step simulation at 60 Hz with render interpolation. This keeps combat
timings (i-frames, attack windows, boss telegraphs) frame-rate independent —
essential when your audience spans a 144 Hz desktop and a throttled laptop.

```ts
// core/Game.ts
const STEP = 1 / 60;
let acc = 0, last = performance.now() / 1000;

function frame(nowMs: number) {
  const now = nowMs / 1000;
  acc += Math.min(now - last, 0.25);  // clamp: never spiral after a tab stall
  last = now;

  while (acc >= STEP) {
    input.snapshot();                 // intent captured once per tick
    world.step(STEP);                 // pure sim: movement, AI, combat, status
    acc -= STEP;
  }

  const alpha = acc / STEP;
  views.sync(world, alpha);           // lerp positions/rotations for rendering
  cameraRig.update(now - last);
  renderer.render(scene, camera);
  requestAnimationFrame(frame);
}
```

The `Math.min(…, 0.25)` clamp matters more in a browser than anywhere else:
backgrounded tabs, GC pauses, and OS sleep all produce multi-second deltas, and
an unclamped accumulator will run 400 sim steps in one frame and freeze the page.

### 1.5 Why no physics engine

Rapier's WASM build is ~400 KB and gives you dynamics you actively don't want:
an action-RPG character that can be shoved by a rigid body feels broken. Build
instead:

- **Character motion:** kinematic capsule, gravity integrated manually, ground
  probed with one downward raycast against a merged collision mesh.
- **Terrain collision:** author a low-poly *collision proxy* per zone (a few
  hundred triangles, invisible), separate from the visual mesh. Raycast against
  the proxy via a BVH (`three-mesh-bvh`, ~40 KB) — orders of magnitude faster
  than naive `Raycaster` against the visual mesh.
- **Combat hits:** sphere/capsule overlap tests only, broadphased through a
  uniform spatial hash (cell ≈ 4 m). With ≤60 active entities this is
  microseconds per tick.
- **Walls:** invisible box colliders placed in the world config; slide response
  is projection onto the wall plane.

Total: ~300 lines, zero dependencies, full determinism, better game feel.

### 1.6 Asset loading & memory

**The budget** (the constraint that shapes everything else):

| Resource | Target | Hard ceiling |
|---|---|---|
| Initial JS bundle | < 400 KB gz | 700 KB |
| Time to first playable | < 5 s on 4G | 10 s |
| Per-zone asset payload | 3–6 MB | 10 MB |
| GPU memory, steady state | < 300 MB | 500 MB |
| Draw calls per frame | < 150 | 300 |
| Triangles per frame | < 250 k | 500 k |

Mobile Safari is the binding constraint — an iOS tab that exceeds roughly
1–1.5 GB total is killed by the OS with no catchable error. WebGL contexts are
*not* garbage collected on their own schedule; you must dispose explicitly.

**Loading strategy — three tiers:**

1. **Core bundle (always resident):** player model + rig, all player VFX, UI, the
   full shared SFX sprite. ~2 MB. Never unloaded.
2. **World pack (per world):** shared props, skybox, material ramps, world music,
   enemy models for that world's roster. ~8–15 MB. Loaded on world entry,
   disposed on world exit.
3. **Zone pack (per zone):** terrain mesh, zone-specific props, spawn layout.
   ~3–6 MB. Prefetched for adjacent zones at low priority while the player is
   idle in a hub.

```ts
// core/AssetRegistry.ts — ref counting is what actually prevents the leak
class AssetRegistry {
  private entries = new Map<string, { asset: GLTF; refs: number }>();

  async acquire(url: string): Promise<GLTF> {
    const hit = this.entries.get(url);
    if (hit) { hit.refs++; return hit.asset; }
    const asset = await this.loader.loadAsync(url);
    this.entries.set(url, { asset, refs: 1 });
    return asset;
  }

  release(url: string) {
    const e = this.entries.get(url);
    if (!e || --e.refs > 0) return;
    e.asset.scene.traverse((o) => {
      if (!(o as Mesh).isMesh) return;
      const m = o as Mesh;
      m.geometry.dispose();
      for (const mat of [m.material].flat()) {
        for (const k of ['map','normalMap','emissiveMap','gradientMap'] as const) {
          (mat as any)[k]?.dispose();
        }
        mat.dispose();
      }
    });
    this.entries.delete(url);
  }
}
```

Ref counting rather than naive dispose-on-zone-exit: a slime model shared by
Zone 1 and Zone 2 must survive the transition between them, and a shared
gradient ramp texture is referenced by nearly everything.

Between zones, `renderer.renderLists.dispose()` and one `THREE.Cache.clear()`.
Verify with `renderer.info.memory` (geometries/textures counts should return to
baseline after unload) — log it in dev on every zone transition; a monotonically
rising count is a leak and will be one, at some point, guaranteed.

**Compression pipeline** (`gltf-transform` CLI in a prebuild step):

```bash
gltf-transform optimize in.glb out.glb \
  --compress draco --texture-compress ktx2 \
  --simplify 0.75 --join --weld --prune --instance
```

Draco: ~90% geometry reduction, needs a 200 KB decoder (lazy-load the WASM).
KTX2/Basis: stays compressed *in VRAM*, unlike PNG — this is the bigger win, and
the decoder is also lazy-loaded. Only pay for the decoders once the first zone
actually loads.

**Instancing is non-negotiable for the environment.** Rocks, grass tufts, trees,
crystals — every repeated prop goes through `InstancedMesh`. A Namek zone with
2,000 rock instances is 1 draw call; as individual meshes it is 2,000 draw calls
and a 12 fps slideshow. Author zones to reuse ~15 prop archetypes with varied
scale/rotation, which is *also* the correct low-poly art direction (§2), so the
performance constraint and the aesthetic point the same way.

### 1.7 Backend: Supabase

**Recommendation: Supabase.**

- Postgres with real relational integrity — inventory, equipment, and progression
  are relational data. Firestore's document model forces you to either duplicate
  item definitions into every save or do N+1 client reads.
- Row Level Security gives per-user isolation with a declarative policy rather
  than Firestore rules' bespoke DSL.
- Edge Functions (Deno) let you move *validation* server-side later without
  changing hosting: the same TypeScript from `sim/formulas.ts` runs there. This
  is the migration path from "trusting the client" to "authoritative server",
  and it's why the sim/render split in §1.3 pays for itself.
- Predictable pricing; self-hostable, so you're never held hostage.
- Anonymous auth for instant play, upgradeable to a real account without losing
  the save — critical for a web game's conversion funnel.

Firebase is a reasonable second choice if you want zero ops and never intend
server-authoritative play. A custom Node + Postgres stack is only worth it once
you have real-time multiplayer or a live economy — you'd be building auth,
sessions, migrations, and hosting for no gain today.

**Schema:**

```sql
create table profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text,
  created_at timestamptz default now()
);

create table characters (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles on delete cascade,
  level int not null default 1,
  xp bigint not null default 0,
  stat_points int not null default 0,
  current_world text not null default 'w1_verdant_reach',
  current_zone text not null default 'z1_landing_flats',
  unlocked_zones text[] not null default '{z1_landing_flats}',
  flags jsonb not null default '{}',      -- boss kills, key items, tutorials
  currencies jsonb not null default '{}', -- { "zeni": 0, "mana_crystal": 0 }
  playtime_s int not null default 0,
  updated_at timestamptz default now(),
  save_version int not null default 1
);

create table inventory_items (
  id uuid primary key default gen_random_uuid(),
  character_id uuid not null references characters on delete cascade,
  item_def_id text not null,              -- key into content/items/*.json
  quantity int not null default 1,
  rarity text not null,
  rolled_affixes jsonb not null default '[]',
  equipped_slot text,                     -- null when in bag
  acquired_at timestamptz default now()
);
create unique index one_item_per_slot
  on inventory_items (character_id, equipped_slot)
  where equipped_slot is not null;

alter table characters enable row level security;
create policy own_characters on characters
  for all using (profile_id = auth.uid()) with check (profile_id = auth.uid());
```

Item *definitions* stay in client JSON; the DB stores only `item_def_id` + rolled
values. Rebalancing a sword is then a static-asset deploy, not a migration.

**Save cadence:** never save per-frame. Write on meaningful transitions — zone
change, level up, boss kill, item equip, tab hidden (`visibilitychange`), and a
30 s debounced heartbeat. Keep an IndexedDB write-ahead copy so a dropped
connection can't eat a session; reconcile on reconnect by `updated_at`.

**Anti-cheat posture, stated honestly:** a client-authoritative browser game is
trivially cheatable, and that is *acceptable* for a single-player PvE game.
Spend nothing on client obfuscation. Do add cheap server-side sanity checks in
an Edge Function on write — level deltas bounded by elapsed playtime, XP totals
consistent with level, item ids that exist, no equipping World 2 gear before the
World 1 boss flag is set. That's enough to keep leaderboards (if you add them)
from being pure noise. Revisit only if you ship trading or PvP.

---

## 2. Art direction

### 2.1 Modeling rules

- **Budgets:** player 3–5 k tris; standard enemy 800–2,000; boss 6–10 k; props
  50–400. A zone's total visible geometry ≤ 250 k tris.
- **Flat shading throughout** (`flatShading: true`, or bake it by splitting
  vertices at export). Faceting *is* the style; smooth normals read as
  "unfinished PS2" rather than "deliberate low-poly."
- **Vertex colors or tiny palette atlases instead of textures.** One 256×256
  palette atlas per world, with UVs pointing at flat color patches, means every
  prop in a world shares one material → aggressive draw-call merging. Reserve
  real textures for the player, bosses, and skyboxes.
- **Characters:** anime silhouette proportions (~6.5 heads), oversized hands and
  hair volumes, simplified faces with texture-mapped eyes on a flat plane —
  never modeled eye geometry at this poly count.
- **Rigs:** ≤ 30 bones. Share one skeleton across all humanoid enemies so
  animations retarget for free; that alone saves weeks of animation work.

### 2.2 Lighting & shading

One shared toon material factory, per-world configured:

```ts
// render/materials/toon.ts
export function makeToonMaterial(cfg: WorldPalette, color: THREE.ColorRepresentation) {
  return new THREE.MeshToonMaterial({
    color,
    gradientMap: rampTexture(cfg.rampStops),  // 3–4 step, NearestFilter
    flatShading: true,
  });
}
```

The gradient ramp is a 1×4 texture with `magFilter: NearestFilter` — that hard
step is the entire anime cel look, and it costs nothing.

Lighting rig per world (only 3 lights; more means more shader permutations and
more shadow passes):

| | Verdant Reach (W1) | Trefoil Marches (W2) |
|---|---|---|
| Sky/ambient | `#7FE3A0` emerald, intensity 0.6 | `#FFF3D0` warm cream, 0.5 |
| Key directional | `#FFB347` amber, 1.2, low angle 25° | `#FFE9B0` gold, 1.0, high 55° |
| Fill/hemisphere | ground `#2E5D3A`, sky `#9FFFC4` | ground `#4A6B32`, sky `#CFE9FF` |
| Fog | `FogExp2 #6FD99A`, density 0.012 | `FogExp2 #DCEBC4`, density 0.006 |
| Tone mapping | ACESFilmic, exposure 1.1 | ACESFilmic, exposure 1.0 |
| Signature | bioluminescent pools, floating rock spires, twin suns | banner-lined stone keeps, clover meadows, shafts of forest light |

Fog is doing double duty: it sells atmosphere *and* hides your draw distance so
you can cut the far plane to ~150 m and halve what you render.

**Post-processing — spend carefully.** Only two effects earn their cost:
selective bloom on emissive materials (energy attacks, crystals, magic) and a
subtle vignette. Skip SSAO (expensive, and flat-shaded geometry barely reads it)
and skip screen-space outlines at first — get outlines from **inverted-hull**
geometry instead (backface-culled duplicate mesh scaled along normals), which is
one extra draw call per outlined object and looks more anime than any
post-process edge detect. Outline only the player, enemies, and interactables;
never the terrain.

**Shadows:** one directional shadow map, 1024², cascade-free, tightly fitted to
a ~40 m box around the player. Enemies and player cast; terrain receives only.
Props neither cast nor receive — use a cheap blob-shadow decal. Shadows are the
first thing to drop in the low-quality tier.

**Quality tiers**, auto-selected from a 2-second startup benchmark, always
user-overridable:

| | Low | Medium | High |
|---|---|---|---|
| Pixel ratio | 0.75 | 1.0 | min(devicePixelRatio, 2) |
| Shadows | off (blobs) | 1024² | 2048² |
| Bloom | off | on | on |
| Outlines | player only | player + enemies | all characters |
| Foliage instances | 25% | 60% | 100% |
| Draw distance | 90 m | 130 m | 180 m |

### 2.3 Camera

**Recommendation: third-person orbit, spring-arm, with a soft lock-on.**

Third-person orbit is the right call because dodge-with-i-frames combat needs the
player to read attack telegraphs *toward the camera*, and because it sells the
verticality (floating spires, keep walls) that both worlds depend on. The costs
are real: you must handle camera-terrain collision, and you render more geometry
because the view frustum sweeps freely.

Fixed isometric would be cheaper — a fixed frustum lets you precompute
visibility per zone, cull aggressively, and never fight camera collision — and it
suits crowd control. But it flattens the anime spectacle, makes vertical arenas
pointless, and reads as "mobile ARPG." For an anime action-RPG the genre
expectation is over-the-shoulder.

```ts
// render/CameraRig.ts — spring arm with collision pull-in
const desired = target.position.clone()
  .add(offsetFromYawPitch(yaw, pitch, distance));

raycaster.set(target.position, desired.clone().sub(target.position).normalize());
const hit = raycaster.intersectObject(zoneCollisionProxy, false)[0];
const clamped = hit ? Math.max(hit.distance - 0.3, MIN_DIST) : distance;

camera.position.lerp(
  target.position.clone().add(offsetFromYawPitch(yaw, pitch, clamped)),
  1 - Math.exp(-SMOOTH * dt)          // frame-rate independent damping
);
```

`1 - Math.exp(-k·dt)` rather than a fixed lerp factor: a constant `0.1` per frame
makes the camera feel different at 30 fps and 144 fps, and that difference is
exactly the kind of bug that gets reported as "combat feels bad on my laptop."

Lock-on: soft: hold a key to bias camera yaw toward the nearest enemy within
20 m and a 60° cone, and break when the target dies or leaves 30 m. Full hard
lock is worth adding for bosses only.

---

## 3. Core gameplay loop

### 3.1 The loop

```
       ┌──────────────────────────────────────────────────┐
       ▼                                                  │
  Enter zone → engage enemy packs → combat → drops + XP ──┤
       │                                                  │
       ├─ level up → spend stat points ───────────────────┤
       ├─ craft/upgrade gear at hub ──────────────────────┤
       ▼                                                  │
  Zone clear threshold met → next zone unlocked ──────────┘
       │
       ▼
  Mid-boss (zone 2) ─── key item ──▶ zones 3-4
       │
       ▼
  World boss (zone 4) ─── world key item + level gate ──▶ WORLD 2
```

Session shape: a 3–5 minute clear-a-zone-segment beat, a 15–20 minute
zone-to-zone beat, a 60–90 minute world beat. Web players arrive in tabs and
leave in tabs — the short beat must feel complete on its own, and progress must
be saved at every one of those boundaries.

### 3.2 Moment-to-moment

Enemies live in **encounter packs** (2–5 enemies with a shared aggro leash),
placed at authored anchor points rather than randomly spawned. Authored placement
lets you tune difficulty curves and teach mechanics in order; random spawning
produces mush. Packs respawn 90 s after being cleared, so a zone stays farmable
without feeling like a treadmill.

Between fights: chests (one guaranteed per zone segment, contents rolled from
the zone's table), a resource node or two, and a shortcut to unlock. Traversal
should take ≤ 20 s between engagements; anything longer and the player is
walking, not playing.

### 3.3 Progression gates — the specific answer

Gating uses **three conditions in AND**, all stored as flags on the character:

| Gate | Requirement | Rationale |
|---|---|---|
| **Level** | ≥ 15 to enter World 2 | Prevents a skilled player from skipping into content that will one-shot them, and guarantees the gear baseline. |
| **Boss kill flag** | `boss.w1_final.killed === true` | The narrative and skill gate. Non-negotiable, non-purchasable. |
| **Key item** | `Fractured Dragon Sigil` (100% boss drop) | The *visible* token. Players understand "I need the thing" far better than "I need a flag." Sits in inventory, is described, is shown on the world map. |

Between zones *within* a world, gating is lighter — a single condition — so the
early game keeps moving:

- Zone 1 → 2: clear the zone-1 pack quota (kill 12 enemies). Effectively free.
- Zone 2 → 3: kill the mid-boss, receive `Elder's Waystone` key item.
- Zone 3 → 4: reach level 12 **or** kill 25 zone-3 enemies (either path — the
  OR here is deliberate: it lets a grinder and a rusher both progress).
- Zone 4: world boss arena, opened by the key item from zone 2.

**Anti-frustration rule:** never gate on an RNG drop. Every gate item is a 100%
guaranteed drop from a specific kill. Farming a 5% key item is the fastest way to
lose a player who has 20 minutes.

---

## 4. World progression structure

### 4.1 World 1 — Verdant Reach (Namek-inspired)

Levels 1–15. Emerald skies, ammonia-blue water pools, orange rock spires,
spiral-roofed alien dwellings.

| Zone | Name | Level | Content |
|---|---|---|---|
| Z1 | Landing Flats | 1–4 | Tutorial. Movement, light/heavy, dodge. 3 packs of Grasshoppers. |
| Z2 | Whispering Pools | 4–8 | Water traversal, ranged enemies. **Mid-boss: Warden Zhun.** |
| Z3 | Spire Ascent | 8–12 | Verticality, ledges, a stagger-check enemy. |
| Z4 | Elder's Hollow | 12–15 | Elite packs, then **World boss: Grand Elder Kaanu, the Hollowed.** |

Enemy tiers:

| Tier | Example | HP | ATK | Behavior |
|---|---|---|---|---|
| Chaff | Namek Grasshopper | 40 | 6 | Melee rusher, no telegraph, dies in 2 hits. Teaches targeting. |
| Standard | Pool Skitterer | 90 | 11 | Ranged spit, kites, repositions. Teaches dodging projectiles. |
| Bruiser | Rockhide Sentinel | 220 | 18 | Slow 1.2 s telegraphed slam, high DEF, staggerable. Teaches heavy attacks. |
| Caster | Spire Acolyte | 120 | 22 | Channels a 2 s beam; interruptible. Teaches priority targeting. |
| Elite | Ascended Warrior | 400 | 28 | Combos, dodges *your* attacks, has its own i-frames. Mini-skill-check. |

### 4.2 World 2 — Trefoil Marches (Clover-inspired)

Levels 15–30. Warm gold light, stone keeps, clover meadows, deep green forest.

**How difficulty scales — four axes, not just numbers:**

1. **Stats:** enemy HP ×2.6, ATK ×2.1, DEF ×2.4 vs. World 1 equivalents.
2. **New mechanics:** grimoire casters place ground AoE (dodge-roll *positioning*
   now matters, not just timing); shield knights require breaking a guard with
   heavy attacks (light attacks are chip damage only); wolves flank in pairs
   (single-target focus gets you killed).
3. **Pack composition:** mixed archetypes — a shield knight fronting two casters
   forces target prioritization, which World 1 never demanded.
4. **Status effects introduced:** Burn (DoT), Bind (slow), Silence (blocks your
   special). Counterplay items enter the loot pool alongside them.

| Zone | Name | Level | Content |
|---|---|---|---|
| Z1 | Clover Meadows | 15–19 | Open field, wolf packs, first grimoire casters. |
| Z2 | Ironbriar Wood | 19–23 | Dense forest, ambushes, Burn status. **Mid-boss: Thornmarshal Vayne.** |
| Z3 | Knight's Bastion | 23–27 | Fortress interior — corridors, guard-break shield knights, Silence. |
| Z4 | Throne of Petals | 27–30 | Elites, then **World boss: Sable Grimoire, the Fifth Leaf.** |

### 4.3 Data-driven world framework

This is the section that determines whether World 3 takes a week or a quarter.
**Adding a world must be: drop in a JSON file, drop in a GLB folder, register the
id.** Zero code changes.

```jsonc
// content/worlds/w1_verdant_reach.json
{
  "id": "w1_verdant_reach",
  "displayName": "Verdant Reach",
  "order": 1,
  "levelRange": [1, 15],
  "unlock": { "type": "default" },

  "palette": {
    "ambient": "#7FE3A0", "ambientIntensity": 0.6,
    "keyLight": { "color": "#FFB347", "intensity": 1.2, "elevation": 25, "azimuth": 130 },
    "hemisphere": { "sky": "#9FFFC4", "ground": "#2E5D3A", "intensity": 0.4 },
    "fog": { "type": "exp2", "color": "#6FD99A", "density": 0.012 },
    "rampStops": ["#2A4D3A", "#4E8F63", "#8FD9A0", "#D8FFE4"],
    "exposure": 1.1
  },

  "assets": {
    "worldPack": "/assets/worlds/verdant/pack.glb",
    "skybox": "/assets/worlds/verdant/sky.ktx2",
    "music": "/assets/audio/verdant_theme.webm"
  },

  "materials": { "currency": "zeni", "craftMaterial": "namekian_crystal" },

  "zones": [
    {
      "id": "z1_landing_flats",
      "displayName": "Landing Flats",
      "levelRange": [1, 4],
      "terrain": "/assets/worlds/verdant/z1_terrain.glb",
      "collision": "/assets/worlds/verdant/z1_collision.glb",
      "props": "/assets/worlds/verdant/z1_props.glb",
      "spawns": [
        { "anchor": [12, 0, -30], "radius": 8, "pack": ["grasshopper", "grasshopper", "grasshopper"], "respawnS": 90 },
        { "anchor": [40, 2, -55], "radius": 10, "pack": ["grasshopper", "pool_skitterer"], "respawnS": 90 }
      ],
      "chests": [{ "at": [22, 0, -44], "table": "chest_w1_common" }],
      "exits": [
        { "to": "z2_whispering_pools", "at": [80, 0, -70],
          "requires": { "type": "killCount", "zone": "z1_landing_flats", "count": 12 } }
      ]
    }
    // … z2, z3, z4
  ],

  "bosses": {
    "mid":   { "id": "warden_zhun",   "zone": "z2_whispering_pools", "arena": "/assets/worlds/verdant/arena_mid.glb" },
    "final": { "id": "grand_elder_kaanu", "zone": "z4_elders_hollow", "arena": "/assets/worlds/verdant/arena_final.glb" }
  },

  "completion": { "grantsKeyItem": "fractured_dragon_sigil" }
}
```

```jsonc
// The next world declares its own gate. Nothing in code knows about "World 2".
{
  "id": "w2_trefoil_marches",
  "order": 2,
  "levelRange": [15, 30],
  "unlock": {
    "type": "all",
    "conditions": [
      { "type": "level",   "min": 15 },
      { "type": "flag",    "key": "boss.grand_elder_kaanu.killed" },
      { "type": "keyItem", "id": "fractured_dragon_sigil" }
    ]
  }
  // … same shape as above
}
```

The unlock condition is a small recursive predicate evaluated by one function:

```ts
// sim/progression.ts
export function isSatisfied(c: Condition, s: CharacterState): boolean {
  switch (c.type) {
    case 'default':   return true;
    case 'level':     return s.level >= c.min;
    case 'flag':      return s.flags[c.key] === true;
    case 'keyItem':   return s.inventory.some(i => i.defId === c.id);
    case 'killCount': return (s.kills[c.zone] ?? 0) >= c.count;
    case 'all':       return c.conditions.every(x => isSatisfied(x, s));
    case 'any':       return c.conditions.some(x => isSatisfied(x, s));
  }
}
```

Every gate in the game — zone exits, world unlocks, vendor stock, quest steps —
routes through this one function. Adding a gate type is one case arm plus one
schema entry.

Enforce the JSON schemas with `ajv` in CI. A designer typo in a world config
should fail the build with a line number, not produce a black screen in
production.

---

## 5. Combat system

### 5.1 Move set & frame data

All timings in seconds; at 60 Hz sim these are exact frame counts.

| Action | Startup | Active | Recovery | Cancellable into | Notes |
|---|---|---|---|---|---|
| Light 1 | 0.10 | 0.08 | 0.22 | Light 2, dodge | Advances ~1 m |
| Light 2 | 0.10 | 0.08 | 0.24 | Light 3, dodge | |
| Light 3 | 0.15 | 0.12 | 0.40 | dodge (after 0.20) | Knockback, 1.35× damage |
| Heavy | 0.35 | 0.14 | 0.50 | dodge (after 0.30) | 2.2× damage, +80 stagger, armor 0.35–0.49 |
| Dodge roll | 0.05 | — | 0.45 | any (after 0.30) | **i-frames 0.10–0.42**, 5 m, costs 25 stamina |
| Special | 0.30 | varies | 0.60 | — | Cooldown-gated, no cost |

Two details that separate combat that feels good from combat that doesn't:

**Input buffering.** Accept an input up to 0.20 s before the current action's
cancel window opens, and fire it the instant the window opens. Without this,
combos feel unresponsive and players report "dropped inputs" — this single
feature is the difference between a combat system people call janky and one they
call crisp.

**Coyote i-frames.** If a hit lands within 0.05 s *before* the dodge's i-frames
begin, still count it as dodged. Nobody notices it's there; everybody notices
when it's missing.

Hit resolution during an active window: sphere cast along the weapon arc,
one hit per entity per swing (tracked in a per-attack `hitSet`), 0.08 s hitstop
on connect (freeze both actors' animation, not the sim — hitstop is *the* cheapest
way to make attacks feel heavy).

### 5.2 Damage formula

```ts
// sim/formulas.ts — pure, unit-tested, reused server-side later
export function computeDamage(a: Attacker, d: Defender, mv: MoveData, rng: RNG): DamageResult {
  const base = a.atk * mv.multiplier;

  // Mitigation: asymptotic, never reaches 100%, no negative-damage cliff.
  // K=100 → 100 DEF halves damage; 300 DEF takes 25%.
  const K = 100;
  const mitigated = base * (K / (K + Math.max(0, d.def)));

  const isCrit = rng.next() < Math.min(a.critChance, 0.75);
  const crit = isCrit ? a.critMultiplier : 1;

  const variance = 0.92 + rng.next() * 0.16;      // ±8%, keeps numbers alive
  const elem = elementalModifier(mv.element, d.resistances); // 0.5 / 1.0 / 1.5

  const raw = mitigated * crit * variance * elem;
  const final = Math.max(1, Math.round(raw));      // never a 0-damage feel-bad

  return { amount: final, isCrit, stagger: mv.stagger * (isCrit ? 1.5 : 1) };
}
```

Why `K/(K+DEF)` rather than `ATK − DEF`: subtractive mitigation breaks at both
ends — it produces zero or negative damage against high DEF, and it makes small
DEF gains swing wildly at low levels. The asymptotic curve gives smooth,
predictable, always-positive scaling, and lets you keep dropping DEF gear
forever without it becoming mandatory.

**Stagger:** every entity has a stagger meter (enemy: 100 × tier multiplier). It
decays 15/s after 1.5 s without being hit. Filling it triggers a 1.2 s stagger
state, during which incoming damage is ×1.5. This is what makes heavy attacks
meaningful against bruisers — light-spam fills stagger too slowly to ever break
them.

### 5.3 Enemy AI

A flat finite state machine per enemy — not behavior trees, not GOAP. With ~10
archetypes, a switch statement is more readable, more debuggable, and faster than
any generic framework, and you can hot-tune it from JSON.

```
IDLE ──player in aggroRadius──▶ AGGRO ──in attackRange & offCd──▶ WINDUP
  ▲                               │                                  │
  │                               │ lost player > 6 s                ▼
  └──────── leash exceeded ───────┤                               ATTACK
                                  │                                  │
                            (hp<25% & flees)                         ▼
                                  ▼                              RECOVER
                                FLEE                                 │
                                                                     ▼
        STAGGER ◀── stagger meter full (interrupts any state) ── AGGRO
           │
           └── 1.2 s ──▶ AGGRO
```

```jsonc
// content/enemies/rockhide_sentinel.json
{
  "id": "rockhide_sentinel", "tier": "bruiser", "model": "/assets/enemies/rockhide.glb",
  "baseStats": { "hp": 220, "atk": 18, "def": 30, "staggerMax": 180 },
  "ai": {
    "aggroRadius": 14, "leashRadius": 28, "attackRange": 3.2,
    "moveSpeed": 2.4, "turnSpeed": 2.0,
    "reactionDelayS": 0.35,
    "fleeAtHpPct": 0,
    "attacks": [
      { "id": "slam",  "weight": 70, "windupS": 1.2, "activeS": 0.2, "recoverS": 0.9,
        "multiplier": 1.6, "range": 3.2, "telegraph": "ring", "cooldownS": 3.5 },
      { "id": "sweep", "weight": 30, "windupS": 0.8, "activeS": 0.3, "recoverS": 0.7,
        "multiplier": 1.1, "range": 4.0, "arc": 180, "telegraph": "cone", "cooldownS": 6.0 }
    ]
  },
  "dropTable": "dt_rockhide"
}
```

**`reactionDelayS` is the most important AI tuning knob in the file.** Enemies
that respond instantly feel like aimbots; 0.2–0.4 s of "thinking" reads as
intelligence and creates the openings that make combat legible.

**AI budget:** run full AI only for enemies within 40 m (`AGGRO`-capable);
beyond that, tick at 4 Hz. With ≤ 60 entities per zone this is a non-issue, but
the tiering means a future crowd zone won't require rearchitecting.

---

## 6. Progression systems

### 6.1 XP curve

```ts
// Total XP required to reach level L (superlinear, gentle early, steeper late)
export const xpToReach = (L: number) => Math.floor(100 * Math.pow(L - 1, 1.85));

// L2:100  L5:1,133  L10:5,297  L15:12,673  L20:23,527  L25:38,062  L30:56,461

// XP granted for a kill, with a level-difference falloff that discourages
// farming trivial content without hard-blocking it.
export function xpForKill(enemyLevel: number, playerLevel: number, tierMul: number) {
  const base = 12 * Math.pow(enemyLevel, 1.4) * tierMul;
  const diff = enemyLevel - playerLevel;
  const falloff =
    diff >= -2 ? 1 :
    diff >= -5 ? 0.6 :
    diff >= -8 ? 0.25 : 0.05;
  return Math.max(1, Math.floor(base * falloff));
}
```

Tier multipliers: chaff 0.6, standard 1.0, bruiser 1.8, caster 1.4, elite 3.5,
mid-boss 25, world boss 80.

Sanity check: reaching level 15 (the World 2 gate) means roughly 12,700 XP,
which is ~90 minutes of steady World 1 play including boss kills. That's the
right length for a first world — long enough to feel like a world, short enough
that the second one arrives before the loop gets stale.

### 6.2 Stats

```ts
export function statsForLevel(level: number, allocated: Allocation): Stats {
  const l = level - 1;
  return {
    maxHp:          Math.floor(100 + l * 18 + allocated.vit * 12),
    atk:            Math.floor(10  + l * 2.4 + allocated.str * 1.8),
    def:            Math.floor(5   + l * 1.6 + allocated.end * 1.4),
    critChance:     Math.min(0.05 + allocated.agi * 0.004, 0.60),  // hard cap
    critMultiplier: 1.5 + allocated.agi * 0.006,
    maxStamina:     100 + allocated.end * 3,
    staminaRegen:   18 + allocated.end * 0.25,
  };
}
```

3 stat points per level, 4 allocatable stats (VIT/STR/END/AGI). Full respec
available at any hub for a currency cost that's trivial early and meaningful
late — experimentation should be encouraged, not punished, but not free either.

Crit chance is hard-capped at 60% deliberately: uncapped crit multiplies with
crit damage and turns endgame balance into a two-variable explosion.

### 6.3 Equipment

Six slots: weapon, head, chest, hands, legs, accessory.

| Rarity | Weight | Affixes | Stat multiplier | Visual |
|---|---|---|---|---|
| Common | 60% | 0 | 1.0× | gray, no FX |
| Uncommon | 25% | 1 | 1.15× | green tint |
| Rare | 11% | 2 | 1.35× | blue, faint emissive |
| Epic | 3.5% | 3 | 1.65× | purple, particle wisp |
| Legendary | 0.5% | 3 + unique passive | 2.0× | gold, trail + light |

Item level scales the base roll: `base = itemLevel * slotCoefficient * rarityMul`,
then affixes roll within their own ranges. Legendaries carry a named passive
(e.g. *"Afterimage: dodging within 0.15 s of an incoming hit refunds 15 stamina
and grants +20% ATK for 3 s"*) — the passives are the reason to chase them, not
the stat multiplier.

**Thematic differentiation** — the worlds should feel different in the hands,
not just on the color swatch:

| | Verdant Reach gear | Trefoil Marches gear |
|---|---|---|
| Fantasy | Martial artist / alien warrior | Magic knight |
| Look | Weighted gi, sashes, segmented alien plate, blue-white energy trim | Tabards, pauldrons, longcoats, heraldic capes, gold filigree |
| Weapons | Fists, staves, energy blades | Longswords, grimoire-bound tomes, greatswords |
| Stat bias | STR / AGI — burst and mobility | VIT / END — sustain and guard-break |
| Affix pool | *Ki Surge* (+special dmg), *Weightless* (+dodge distance), *Afterimage* | *Mana Font* (−cooldowns), *Warded* (+status resist), *Bannered* (+dmg vs staggered) |

The stat-bias split is the mechanically important part: World 2 gear isn't merely
*better*, it plays differently, so arriving in World 2 means re-evaluating your
build rather than replacing every number with a bigger one.

---

## 7. Loot & drop system

### 7.1 Drop tables

```jsonc
// content/droptables/dt_rockhide.json
{
  "id": "dt_rockhide",
  "currency": { "min": 18, "max": 34 },
  "guaranteed": [
    { "item": "namekian_crystal", "min": 1, "max": 2 }
  ],
  "rolls": 2,                     // independent rolls against the weighted pool
  "pool": [
    { "item": null,               "weight": 400 },   // "nothing" is a real entry
    { "item": "stone_shard",      "weight": 250 },
    { "item": "sentinel_plate",   "weight": 120, "rarityOverride": "uncommon" },
    { "item": "roll:w1_armor",    "weight": 60  },   // nested table reference
    { "item": "roll:w1_weapon",   "weight": 40  },
    { "item": "hollowed_core",    "weight": 8,  "rarityOverride": "rare" }
  ],
  "pityCounter": { "trackKey": "rockhide_rare", "after": 40, "grants": "hollowed_core" }
}
```

Include an explicit `null` entry rather than "sometimes the roll fails." It makes
the drop rate for every real item readable directly off the weights
(`weight / totalWeight`), which is what you'll want when a spreadsheet says drops
feel bad and you need to know *why*.

```ts
export function rollTable(t: DropTable, luck: number, rng: RNG, pity: PityState): Drop[] {
  const out: Drop[] = [];
  for (const g of t.guaranteed) {
    out.push({ item: g.item, qty: randInt(rng, g.min, g.max) });
  }
  for (let i = 0; i < t.rolls; i++) {
    const pool = t.pool.map(e => ({
      ...e,
      weight: e.item === null ? e.weight * (1 - luck * 0.3) : e.weight,
    }));
    const picked = weightedPick(pool, rng);
    if (picked.item) out.push(resolveEntry(picked, rng));
  }
  if (t.pityCounter && ++pity[t.pityCounter.trackKey] >= t.pityCounter.after) {
    out.push({ item: t.pityCounter.grants, qty: 1 });
    pity[t.pityCounter.trackKey] = 0;
  }
  return out;
}
```

**Pity counters are not optional.** Without one, a 1% drop means ~1 player in 100
kills it 300 times and quits. Pity converts a long tail of miserable outliers
into a guaranteed ceiling, and costs you almost nothing in median pacing.

Seed the RNG per kill from `(characterId, enemyInstanceId, killCount)` — that
makes drops reproducible for bug reports and for a future server-authoritative
check, and it means "save-scumming by reloading" doesn't work.

### 7.2 Currencies & materials

| Kind | Verdant Reach | Trefoil Marches | Use |
|---|---|---|---|
| Currency | **Zeni** | **Yul Marks** | Vendors, respec, repairs. Converts 1:1 at a 15% hub fee — soft-binds you to spending locally without stranding old money. |
| Common material | Stone Shard | Ironbriar Bark | Tier 1–2 upgrades |
| World material | **Namekian Crystal** | **Clover Mana Shard** | Tier 3+ upgrades, world-exclusive recipes |
| Rare material | Hollowed Core | Fifth-Leaf Fragment | Legendary crafting; boss-weighted |

World-exclusive materials do real design work: they give World 1 zones a reason
to exist after you've outleveled them (World 2 legendary recipes still want
Namekian Crystal), which extends content lifetime for free.

### 7.3 Boss drops

Every boss: 100% key item, 100% one guaranteed Epic from a small themed pool,
and a 15% Legendary chance with a pity counter at 6 kills. First kill grants a
one-time bonus package (currency + a cosmetic title). That first-kill bonus is
what makes bosses feel like events rather than loot piñatas.

---

## 8. Boss design

### 8.1 Shared framework

Bosses are data — a phase list with weighted attack pools — driven by the same
FSM as regular enemies plus a phase controller.

```jsonc
{
  "id": "grand_elder_kaanu",
  "hp": 4200, "atk": 42, "def": 55, "staggerMax": 600,
  "arena": { "radius": 26, "hazards": ["rising_pools"] },
  "phases": [
    { "hpAbove": 0.66, "attacks": ["ground_slam","spirit_bolt"], "moveSpeed": 2.8 },
    { "hpAbove": 0.33, "attacks": ["ground_slam","spirit_bolt","summon_echoes","beam_sweep"],
      "moveSpeed": 3.4, "onEnter": "roar_stagger_immune_2s" },
    { "hpAbove": 0.0,  "attacks": ["beam_sweep","desperation_nova","summon_echoes"],
      "moveSpeed": 3.8, "onEnter": "arena_flood", "damageMul": 1.25 }
  ]
}
```

### 8.2 Telegraphing rules

Non-negotiable, because they're what makes a boss *fair*:

- Every attack has a visible telegraph ≥ 0.6 s before its active frames.
- Telegraph shapes are rendered as ground decals (a projected circle, cone, or
  line) — always readable regardless of camera angle, unlike an animation cue.
- Colour language is consistent across the entire game: **red = dodge**,
  **yellow = block/guard-break**, **blue = punish window open**.
- One audio cue per attack, mixed above everything else.
- Every phase transition is a 2 s stagger-immune roar that also resets the
  arena — the player gets a beat to breathe and to read the new state.

### 8.3 The four bosses

**Warden Zhun** (W1 mid, ~lvl 7, 1,400 HP) — teaches dodge timing. Two phases.
P1: telegraphed lunges and a water-jet line attack. P2 (below 50%): adds
summoned skitterers and a slow rotating pool AoE that shrinks the arena. Drops
`Elder's Waystone`.

**Grand Elder Kaanu, the Hollowed** (W1 final, ~lvl 15, 4,200 HP) — the exam on
everything World 1 taught. Three phases as above; P3 floods the arena floor,
forcing you onto rising rock platforms so positioning and dodge *distance*
matter, not just timing. Drops `Fractured Dragon Sigil` (World 2 key).

**Thornmarshal Vayne** (W2 mid, ~lvl 21, 9,000 HP) — teaches status counterplay.
Applies Burn stacks; the arena has water pools that cleanse them, so the fight is
about routing, not just damage. P2 summons briar walls that reshape the arena.

**Sable Grimoire, the Fifth Leaf** (W2 final, ~lvl 30, 22,000 HP) — four phases,
each channelling a different grimoire element with a different mechanic: fire
(dodge AoE), bind (break free by dodging on a rhythm), silence (special disabled
— pure weapon play), and a final desperation phase combining all three with a
90 s soft enrage. Drops `Sable Leaf` (World 3 key — ship the item before World 3
exists so the hook is already planted).

### 8.4 Arena design

Circular or near-circular, 22–30 m radius, with clear boundaries you can read
without looking at a minimap. Include 2–4 environmental features: cover pillars
(that break), elevation for repositioning, and a hazard that becomes relevant in
a later phase. Load the arena as a **separate zone** with its own asset pack —
that way its higher poly budget and unique props don't tax the exploration zone,
and the load screen is a natural place to put the boss name card.

---

## 9. UI/UX

### 9.1 DOM overlay, not canvas UI

Render all UI as React over the canvas. Text rendering in WebGL is genuinely
painful (SDF atlases, per-glyph geometry, no reflow), while DOM gives you
accessibility, keyboard nav, i18n, and CSS transitions for free — and screen
readers, which no in-canvas UI will ever provide. The overlay costs nothing as
long as you **never re-render React from the game loop**: subscribe HUD
components to Zustand selectors that the sim updates at a throttled 10–15 Hz, not
60. Health numbers changing 15 times a second are indistinguishable from 60 to a
human eye and cost a quarter of the reconciliation.

### 9.2 Screens

**HUD (always on):** health bar top-left with a delayed "damage ghost" trailing
bar (reads as impact); stamina arc under the reticle; XP bar bottom; ability
icons with radial cooldown sweeps; damage numbers floating from hit points
(pooled DOM elements — never allocate per hit); target's health bar top-center on
lock-on; minimap top-right (an orthographic top-down render at 5 Hz to a small
render target, not a second full scene).

**Inventory:** grid, drag-to-equip, rarity-bordered slots, and — the one feature
that most matters — a **comparison tooltip** showing green/red stat deltas
against what's currently equipped. Sort by rarity/level/slot, and a "mark as
junk" + "sell all junk" flow so bag management never becomes the game.

**Character sheet:** all derived stats with hover explanations of *how* each is
computed (a player who understands the DEF curve engages with gear choices), a
stat-point allocator with undo-before-confirm, and an equipped-set panel.

**World map:** stylized 2D illustration per world, zones as nodes with completion
state (locked / available / cleared / boss-available). Locked nodes show the
exact unlock requirement — never a bare padlock. "Reach level 15, defeat Grand
Elder Kaanu" is a goal; a padlock is a wall.

**Pause / settings:** quality tier override, sensitivity, master/SFX/music
volume, key rebinding, and colourblind-safe telegraph palettes (red/yellow are
the worst possible default pair for deuteranopia — offer a blue/orange alternate,
and pair colour with shape so the language never depends on hue alone).

### 9.3 Feel details worth building early

Screen shake on heavy hits (small, decaying, and toggleable); hitstop; a
controller-style radial flash on taking damage; auto-pause on tab blur;
"press any key" resume. These are cheap and they carry more perceived polish than
any amount of extra geometry.

---

## 10. MVP scope

### 10.1 Prototype (target: 6–8 weeks, one dev + contract art)

**In scope — this is a vertical slice, not a demo of everything:**

- One zone: Landing Flats (Verdant Reach Z1), ~120×120 m, fully art-passed.
- Player: full move set — light 3-chain, heavy, dodge with i-frames, one special.
- Two enemy archetypes: Grasshopper (chaff) + Rockhide Sentinel (bruiser). They
  teach different things, which is why two beats five copies of one.
- One boss: Warden Zhun, two phases, in its own arena.
- Combat: damage formula, crit, stagger, hitstop, damage numbers.
- Progression: levels 1–8, stat points, XP bar.
- Loot: drop tables, 12 items across 3 rarities, inventory + equip + compare.
- Save: Supabase anonymous auth, autosave on transitions.
- HUD + inventory + character sheet. No world map yet (single zone).
- Quality tiers with auto-detection.

**Explicitly out of scope for the prototype:** World 2, crafting, vendors, world
map, minimap, affix rolls, legendaries, cosmetics, audio beyond placeholder,
story, dialogue, cutscenes.

**Prototype success criteria — decide these before you start, and be willing to
act on them:**

- Holds 60 fps on a 2019 mid-range laptop at Medium.
- < 5 s to first playable input on a 4G connection.
- 10 external playtesters; ≥ 7 voluntarily replay the boss after their first kill.
- Combat rated "responsive" by ≥ 8/10 — if it isn't, fix feel before adding
  content. Content on top of bad combat is wasted content.

### 10.2 Roadmap after the slice

| Phase | Content | Est. |
|---|---|---|
| **Alpha** | Verdant Reach complete: 4 zones, 5 enemy types, both bosses, levels 1–15, crafting, hub vendor, world map | +8–10 wks |
| **Beta** | Trefoil Marches complete: 4 zones, 6 new enemies, statuses, both bosses, levels 15–30, affixes + legendaries, full audio | +10–12 wks |
| **1.0** | Polish, accessibility, localization scaffolding, analytics-driven balance pass, gamepad, cosmetics | +6 wks |
| **Post** | World 3 (validating the framework — if it isn't mostly a content drop, §4.3 failed), endless mode, daily runs, optional co-op | ongoing |

**Build World 3 as a content-only drop as early as you can bear to** — even a
throwaway two-zone stub. It's the only real test of whether the data-driven
architecture works, and finding out during World 3 proper is far too late.

---

## 11. Risk register & trade-offs summary

| Risk | Impact | Mitigation |
|---|---|---|
| iOS Safari memory kill (~1–1.5 GB, uncatchable) | Session loss, no error to handle | Hard 6 MB/zone budget; ref-counted disposal; test on real devices every sprint, not just simulators |
| Draw-call blowup from prop variety | fps collapse | `InstancedMesh` mandatory; CI check failing the build above 300 draw calls in a benchmark scene |
| First-load abandonment | Kills conversion before gameplay matters | < 400 KB initial bundle; playable in Zone 1 while the rest streams; lazy Draco/KTX2 decoders |
| Client-authoritative saves are cheatable | Low, for solo PvE | Accept it. Cheap Edge Function sanity checks only. Revisit if PvP/trading ships |
| Combat feel misses | Fatal — nothing recovers a bad core loop | Input buffering, coyote i-frames, hitstop, frame-independent damping from day one; playtest at week 3, not week 8 |
| Art scope creep | Schedule | Shared humanoid skeleton, ~15 prop archetypes per world, palette atlas over textures |
| World config drifts from code | Silent breakage | ajv schema validation in CI; unknown enum values fail the build |
| Content pipeline bottleneck | World 3+ slips | Enforce the "no code changes for a new world" rule with a stub World 3 built early |

### The three trade-offs to internalize

1. **Fidelity vs. reach.** Every quality bump narrows your audience. A browser
   game's advantage is that it runs *anywhere* — protect that. The Low tier
   should be genuinely playable on integrated graphics, not a courtesy.
2. **Determinism vs. convenience.** The pure-sim rule (§1.3) costs discipline
   daily and buys testability, reproducible bug reports, and a server-authoritative
   path that doesn't require a rewrite. Hold the line early; it's unrecoverable
   later.
3. **Data-driven vs. bespoke.** Data-driven content is slower for World 1 and
   dramatically faster from World 2 onward. The break-even is roughly the middle
   of World 2 — which means it looks like a mistake for the first three months
   and pays for the rest of the project's life.
