# Math Weapon Arena

Two teams of AI agents fight by **designing their own weapons and shields out of
math**. Each agent writes expressions describing a projectile's flight path and a
shield's shape; the arena compiles them and simulates the battle.

You configure each team exactly like the endpoint panel in your screenshot —
Base URL, API format, API key, model — and the two teams are then wired against
each other.

## Run it

```bash
node arena/serve.js          # http://localhost:8080
node arena/test.js           # headless checks (92 assertions)
```

It has to be served over http, not opened as a `file://` URL, because the app
loads as ES modules.

**No API key?** It still runs. A team without a key falls back to a built-in
offline designer that plays by the same rules, so you can watch a full match
before wiring anything up.

## Configuring the teams

Each team panel takes:

| Field | Notes |
| --- | --- |
| Base URL | e.g. `http://106.54.43.21:3000/v1` — the `/chat/completions` path is appended |
| API format | Chat completions (the only format the arena speaks) |
| API key | Sent as `Authorization: Bearer …`; stored in your browser's localStorage only |
| Model | e.g. `gpt-5.6-sol`. **Test** does a live round-trip and shows `Connected!` with the latency |

Team 1 and Team 2 can point at completely different providers and models — that
is the point. Put one model on each side and see whose ordnance design wins.

### "Load failed" / "Failed to fetch" when you enter a key

Two different browser-level blocks produce that message, and neither means your
endpoint is broken:

- **Mixed content.** A page served over `https` cannot call an `http` endpoint.
  The browser blocks it before the request is sent, which is why the error has
  no detail. This is what you hit on the deployed site.
- **CORS.** The endpoint works, but doesn't send `Access-Control-Allow-Origin`,
  so the browser discards the response.

Both are fixed by the **"Route through server relay"** checkbox on the team
panel: the request is forwarded by this app's own Node server, where neither
mixed content nor CORS applies. It switches itself on automatically when an
`http` endpoint is entered on an `https` page.

The trade-off is real and worth stating: with the relay on, your API key is sent
to the server hosting the arena so it can be forwarded upstream. Direct calls
keep the key in your browser. On your own deployment that's your own server; on
someone else's, it isn't.

## The arena rules

These are stated in the agent prompt, but the prompt is not the enforcement —
`rules.js` is. Everything an agent submits is validated, clamped or repaired
before it can touch the simulation, and every correction is reported in the
referee log so you can see what got overruled.

1. **No one-shot kills.** Units have 100 HP and per-hit damage is hard-capped at
   45. Two hits leave a unit at 10 HP, so **every enemy withstands at least two
   attacks**; the third can finish it. An agent asking for 9999 damage gets 45.
2. **Every shot must curve.** The referee samples each trajectory and measures
   its maximum perpendicular deviation from the straight line between launch and
   impact. Under 14px it isn't a curve — the shot is rejected and replaced with
   a generic arc. A linear `path.y` does not count as curved.
3. **Math only.** Agents submit expressions in a small language that is
   tokenized, parsed and evaluated by `mathlang.js`. There is no `eval`, no
   `Function`, and no reachable global. `document.cookie` is a parse error.
4. **Agents compute their own aim.** Nothing auto-aims and nothing steers a shot
   after launch. The launch angle is whatever the agent's `aim` expression
   evaluates to. Omit it and the referee fires straight at the target with no
   lead and no curve correction — legal, and a wasted turn.

Beyond the rules, every numeric field is clamped to a sane band (projectile
count 1–5, cooldown 0.35–4s, shield absorb 0–85%, shield radius ≤ 58px), so no
agent can win by submitting large numbers.

## What an agent submits

```json
{
  "callsign": "Vector-1",
  "doctrine": "Wrap shots around their open left flank.",
  "weapon": {
    "name": "Sine Lance",
    "damage": 26, "count": 2, "cooldown": 1.0,
    "speed": 320, "range": 520, "radius": 5,
    "aim": "atan2(ty + tvy * hypot(tx-sx, ty-sy) / speed - sy, tx + tvx * hypot(tx-sx, ty-sy) / speed - sx) - atan2(0, 520)",
    "path": {
      "x": "t * d",
      "y": "sin(t * pi) * 74 * (1 - 2 * mod(i, 2))"
    }
  },
  "shield": {
    "name": "Cardioid Ward",
    "capacity": 55, "regen": 5, "absorb": 0.55,
    "shape": "30 * (1 + 0.55 * cos(a))"
  }
}
```

### Path frame

The path is expressed in the barrel's frame at the moment of firing: `+x` runs
along the launch angle, `+y` is 90° clockwise from it on screen. Variables:

| Variable | Meaning |
| --- | --- |
| `t` | flight progress, 0 → 1 |
| `i` | projectile index within the volley (0-based) |
| `n` | projectiles in the volley |
| `d` | the weapon's range |

`path.y` is the curve. `sin(t * pi) * 80` is a clean arc; multiplying by
`(1 - 2 * mod(i, 2))` mirrors alternate projectiles so a volley braids.

### Shield frame

`shape` is a polar radius `r(a, t)` where `a` is the angle in radians with `0`
facing the enemy, and `t` is seconds since the round started. This is what makes
shields interesting: the shield only absorbs where it actually *is*. A
front-loaded bastion like `18 + 32 * bump(a, 0, 0.8)` is nearly impenetrable
head-on and wide open at the sides — which is exactly what a curved shot is for.

`28 + 10 * sin(t * 2 + a * 2)` gives a shield that pulses over time.

### Available functions

`sin cos tan asin acos atan atan2 sinh cosh tanh abs sqrt cbrt exp log floor
ceil round sign min max hypot pow mod clamp lerp bump tri sqr step smoothstep`

Constants: `pi tau e phi`. Operators: `+ - * / % ^` and parentheses.

## How a match runs

A match is **turn-based**. Every unit designs an opening loadout, then each
round **exactly one bot per team attacks** — the turn rotates through the living
units, so everyone gets a go and no single build carries the match.

A turn runs in three beats:

1. **Announce.** The attacker declares itself on screen — callsign, the name it
   gave its weapon, and the equation it is about to fire, `y(t) = …`, with a
   countdown bar showing when the shot goes out.
2. **Fire.** One volley. No second try.
3. **Settle.** Leftover projectiles resolve, then the other team takes its turn.

HP and shield charge **persist across rounds**, so the two-attack survival rule
plays out over the whole match rather than resetting. The match ends when a team
is eliminated or the rounds run out (most HP remaining wins).

Only the two attackers redesign each round, and they are handed real intel: the
enemy's weapon, their actual `path.y`, damage dealt, and — most usefully — their
**shield radius sampled every 45°**, with the thinnest arc called out. That is
the gap an agent is supposed to curve into.

## How hard the agents think

With **Deep design (2-pass)** enabled (default), each attacker goes through two
rounds of reasoning per turn:

1. **Draft.** The agent must first work the problem numerically in an `analysis`
   field: name the enemy's weakest shield angle, estimate the lateral offset
   needed at impact to enter through it, pick the expression that produces that
   offset, and derive its damage split from the two-hit cap arithmetic.
2. **Critique.** The draft is sent back with a checklist: compute where your
   shot *actually* lands relative to the shield profile, confirm the bend passes
   the referee and the path still reaches, check whether a different damage split
   kills faster, and find your own shield's blind arc. The agent then resubmits a
   corrected build.

Both passes are kept. The agent's reasoning is shown under **Agent's reasoning**
on each loadout card, so you can read why a design was chosen and judge whether
the second pass actually improved it. Turn the checkbox off for one-pass designs
(faster, and half the API calls).

## Aiming is the agent's job

This is the part that makes the curve matter. An agent gets raw geometry and
nothing pre-solved — deliberately **not** the bearing to the target:

| Variable | Meaning |
| --- | --- |
| `sx`, `sy` | your position at the moment of firing |
| `tx`, `ty` | the target's position |
| `tvx`, `tvy` | the target's velocity, px/s — units drift, so they lead |
| `speed` | projectile speed |
| `range` | weapon range |

`atan2(ty - sy, tx - sx)` points straight at where the target is standing, and
that misses for two compounding reasons the agent has to correct:

1. **Lead.** The target is moving. The shot takes `hypot(tx-sx, ty-sy) / speed`
   seconds to arrive, so the aim has to go where the target *will* be.
2. **Curve offset.** The agent's own `path.y` displaces the shot sideways. At
   impact it is `path.y(1)` pixels off the barrel line, so a shot aimed straight
   at the target lands that far beside it. Rotating the aim back by
   `atan2(y(1), x(1))` brings the *end of the curve* onto the target.

The second correction is the interesting one: an agent has to evaluate its own
expression at `t = 1` to know what to subtract. Get it wrong and the shot sails
past. In the test suite the same weapon fired with a naive aim lands 2 hits over
four rounds; with the geometry solved it lands 5.

Homing was removed along with this change — a shot that re-aims itself in flight
is auto-aim by another name, and it made the firing solution pointless.

## Recording

The whole match is recorded from the canvas — including the announcement cards
and the thinking phases — and **Download recording** saves it as a `.webm` once
the match ends.

One detail worth knowing: `MediaRecorder` records live and so never writes a
duration into the file, which leaves players showing 0:00 and refusing to seek.
`webm.js` patches the real duration into the container's Segment Info header
after recording stops, so the file behaves like a normal video.

## Files

| File | Role |
| --- | --- |
| `mathlang.js` | The safe expression language: tokenizer, parser, evaluator |
| `rules.js` | Rule enforcement — damage cap, curve check, clamping, compilation |
| `agents.js` | Endpoint calls, the agent prompts, reply parsing, offline designer |
| `sim.js` | The turn-based simulation (fixed 60Hz timestep, deterministic) |
| `app.js` | UI, match loop, canvas renderer, recorder |
| `webm.js` | Writes the duration into the recorded WebM |
| `serve.js` | Static server + CORS relay |
| `test.js` | Headless checks for the language, the rules and the sim |
