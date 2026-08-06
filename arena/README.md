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
node arena/test.js           # headless checks (39 assertions)
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

## The three arena rules

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
    "speed": 320, "range": 520, "radius": 5, "homing": 0.1,
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

The path is expressed in the unit's own aiming frame at the moment of firing:
`+x` points at the target, `+y` is to the left. Variables:

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

Each round: both teams' agents design a loadout per unit **in parallel**, the
referee validates them, and the battle plays out on the canvas. Afterwards each
team is handed **intel on the enemy's loadouts** — their weapon names, their
actual `path.y` and shield `shape` expressions, damage dealt, who survived — plus
any referee corrections against their own submission. So round 2 is a genuine
counter-design, and you can watch the arms race in the loadout panel.

Rounds end on team elimination or a 45s time limit (most HP remaining wins).

## Files

| File | Role |
| --- | --- |
| `mathlang.js` | The safe expression language: tokenizer, parser, evaluator |
| `rules.js` | Rule enforcement — damage cap, curve check, clamping, compilation |
| `agents.js` | Endpoint calls, the agent prompt, reply parsing, offline designer |
| `sim.js` | The combat simulation (fixed 60Hz timestep, deterministic) |
| `app.js` | UI, round loop, canvas renderer |
| `serve.js` | Static server + CORS relay |
| `test.js` | Headless checks for the language, the rules and the sim |
