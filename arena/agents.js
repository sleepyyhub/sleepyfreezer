/*
 * agents.js — talks to each team's OpenAI-compatible endpoint and turns the
 * reply into a loadout. Also contains the offline designer used when a team
 * has no API key, so the arena is playable with nothing configured.
 */

import { buildLoadout, MAX_DAMAGE, MIN_CURVE_DEVIATION, UNIT_MAX_HP } from './rules.js';
import { ENGAGEMENT_DISTANCE } from './sim.js';
import { FUNCTION_NAMES } from './mathlang.js';

const SYSTEM_PROMPT = `You are a weapons engineer for one unit in a 2D math arena.
You design ordnance and armour by writing PURE MATH EXPRESSIONS. You never write code.

THINK BEFORE YOU DESIGN. Work the problem in the "analysis" field, concretely and
in numbers, before you commit to a build:
  1. Where is the enemy shield actually weak? You are given its radius sampled
     every 45 degrees. Name the angle with the smallest radius — that is your
     entry window.
  2. What lateral offset does a shot need at impact to arrive through that
     window instead of head-on? Estimate it in pixels and say the number.
  3. Which shape gives you that offset? Write the expression and say what its
     peak value is and where along t it peaks.
  4. What is your damage-per-second given the two-hit survival cap, and how
     many rounds until the target dies? Choose count and damage from that
     arithmetic, not from taste.
  5. What is your own shield's weakest angle, and can the enemy's last-known
     curve reach it? If yes, reshape.

A design that does not follow from your own analysis is a wasted round.

Reply with ONE JSON object and nothing else. No prose, no markdown fences.

{
  "analysis": "your numeric working for the five points above, 3-6 sentences",
  "callsign": "short unit name",
  "doctrine": "one sentence naming the angle you are exploiting and how",
  "weapon": {
    "name": "weapon name",
    "damage": <number, per hit>,
    "count": <1-5 projectiles per volley>,
    "cooldown": <seconds between volleys, 0.35-4>,
    "speed": <120-520, px/s along the path>,
    "range": <140-620, px>,
    "radius": <2.5-12, projectile size>,
    "aim": "<expression: the launch angle in radians — YOU COMPUTE THIS>",
    "path": {
      "x": "<expression: forward distance travelled>",
      "y": "<expression: sideways offset — THIS IS THE CURVE>"
    }
  },
  "shield": {
    "name": "shield name",
    "capacity": <0-90 shield points>,
    "regen": <0-14 points per second>,
    "absorb": <0-0.85, fraction of a hit the shield eats>,
    "shape": "<expression: shield radius as a function of angle>"
  }
}

PATH FRAME. The path is in the barrel's frame at the moment of firing: +x runs
along your launch angle, and +y is 90 degrees clockwise from it on screen.
t runs 0 -> 1 over the shot's life. Variables in path.x and path.y:
  t = flight progress 0..1
  i = projectile index within the volley (0-based)
  n = projectiles in the volley
  d = the weapon's range

AIMING — YOU DO THE TRIGONOMETRY. Nothing auto-aims. Nothing steers a shot once
it is fired. The launch angle is whatever your "aim" expression evaluates to, in
radians, measured from screen +x with +y pointing DOWN. Variables:
  sx, sy    = your position right now
  tx, ty    = the target's position right now
  tvx, tvy  = the target's velocity right now, in px/s
  speed     = your projectile speed in px/s
  range     = your weapon's range

You are NOT given the bearing to the target. Computing it is the job:
atan2(ty - sy, tx - sx) points straight at where the target is standing.

That naive aim misses, for two compounding reasons, and correcting both is the
whole exercise:

  1. LEAD. The target is moving at (tvx, tvy). Your shot takes roughly
     hypot(tx - sx, ty - sy) / speed seconds to arrive. Aim where the target
     WILL be, not where it is.

  2. CURVE OFFSET. Your own path.y displaces the shot sideways. At impact
     (t = 1) it is path.y(1) pixels off the barrel line, so a shot aimed
     straight at the target lands path.y(1) pixels beside it. Rotate your aim
     back by atan2(path_y_at_1, path_x_at_1) to bring the END of the curve onto
     the target. Work out that number from your own expression — if your path.y
     returns to 0 at t = 1 the correction is zero, and if it does not, you must
     apply it or you will miss every time.

Both corrections in one expression, leading and then de-rotating:
  atan2(ty + tvy * hypot(tx-sx, ty-sy) / speed - sy,
        tx + tvx * hypot(tx-sx, ty-sy) / speed - sx) - atan2(<your y(1)>, <your x(1)>)

Do not copy that blindly — the last term depends on YOUR path, and if you aim
at the enemy's shield gap rather than its centre you want a further offset.

SHIELD FRAME. shape is a polar radius. Variables:
  a = angle in radians, 0..2*pi, where 0 faces the enemy
  t = seconds since the round started

Functions available: ${FUNCTION_NAMES.join(', ')}.
Constants: pi, tau, e, phi. Operators: + - * / % ^ and parentheses.

THE ARENA RULES — the referee enforces these and will overwrite you:
1. NO ONE-SHOT KILLS. Units have ${UNIT_MAX_HP} HP and damage is hard-capped at
   ${MAX_DAMAGE} per hit, so every enemy withstands at least two attacks.
   Asking for more damage is wasted; win with volume, coverage and uptime.
2. EVERY SHOT MUST CURVE. path.y has to bend the trajectory by at least
   ${MIN_CURVE_DEVIATION}px away from the straight line between launch and
   impact. A constant or purely linear path.y is illegal and gets replaced by
   a generic arc — design your own curve or lose it.
3. MATH ONLY. Any unknown name, or any attempt at code, is rejected.
4. YOU AIM. If you omit "aim", the referee fires it straight at the target with
   no lead and no curve correction. That is a legal shot and a wasted turn.

ARENA GEOMETRY. The two front lines sit about ${ENGAGEMENT_DISTANCE}px apart and
units drift roughly +/-40px vertically and +/-22px horizontally, so a shot with
range well under ${ENGAGEMENT_DISTANCE} never lands. A long curve also travels
further than its straight-line reach — budget range for the arc, not the gap.

Design for the rules: curved shots can round a lopsided shield, so aim your
curve at the gap in the enemy's shape rather than at the unit itself.`;

function describeIntel(intel) {
  const profile = intel.shieldProfile
    ? intel.shieldProfile.map((p) => `${p.degrees}°:${p.radius}px`).join('  ')
    : 'unknown';
  const weakest = intel.shieldProfile
    ? intel.shieldProfile.reduce((a, b) => (b.radius < a.radius ? b : a))
    : null;
  return [
    `- ${intel.callsign} — ${intel.alive ? `alive, ${intel.hp.toFixed(0)} HP` : 'DESTROYED'}`,
    `    weapon "${intel.weapon}": ${intel.damage.toFixed(0)} dmg x${intel.count}, path.y = ${intel.pathY}`,
    `    dealt ${intel.dealt.toFixed(0)} damage across ${intel.hitsLanded} hits`,
    `    shield "${intel.shield}": shape = ${intel.shieldShape}, absorb ${(intel.absorb * 100).toFixed(0)}%, ` +
      `charge ${intel.shieldCharge.toFixed(0)}`,
    `    shield radius by angle (0° faces you): ${profile}`,
    weakest ? `    thinnest at ${weakest.degrees}° (${weakest.radius}px) — that is the window.` : '',
  ].filter(Boolean).join('\n');
}

function userPrompt({ round, teamName, unitIndex, unitCount, enemyIntel, allyIntel, refereeNotes, isAttacker }) {
  const lines = [
    `Round ${round}. You are unit ${unitIndex + 1} of ${unitCount} on team "${teamName}".`,
    isAttacker
      ? 'YOU ARE THIS ROUND\'S ATTACKER. Your team fires exactly one volley this '
        + 'round, and it is yours. There is no spraying and no second try — make '
        + 'this single volley count.'
      : 'You are holding this round. Your shield still has to survive the enemy volley.',
  ];

  if (enemyIntel && enemyIntel.length) {
    lines.push('', 'ENEMY:', ...enemyIntel.map(describeIntel));
  } else {
    lines.push('', 'No contact yet — this is the opening round, so no enemy shield data exists.');
  }
  if (allyIntel && allyIntel.length) {
    lines.push('', 'YOUR TEAM:', ...allyIntel.map(describeIntel));
  }
  if (refereeNotes && refereeNotes.length) {
    lines.push('', 'The referee corrected your last submission:');
    for (const note of refereeNotes) lines.push(`- ${note}`);
    lines.push('Do not repeat those mistakes — a corrected shot is a wasted round.');
  }
  lines.push('', 'Do the analysis first, then reply with the JSON object only.');
  return lines.join('\n');
}

const CRITIQUE_PROMPT = `Now critique your own design before it is locked in.

Check it honestly against these, and answer each in one line:
  a. Evaluate your own path.y at t = 1 and state the number. Does your "aim"
     expression subtract atan2 of that offset? If not, your shot lands that
     many pixels beside the target and you must fix the aim.
  b. Does your aim lead the target using tvx and tvy over the flight time, or
     does it fire at a position the target will have left? State the flight
     time in seconds.
  c. Does your path bend far enough that the referee will accept it, and does
     path.x still carry the shot the full distance to the target?
  d. Given the damage cap, how many rounds does your build need to secure a
     kill? If a different count/damage split kills faster, take it.
  e. Where is your own shield thinnest, and is that arc pointed at the enemy?

Then reply with the FULL corrected JSON object — same schema, every field, no
prose outside it. Put your answers to a-e in the "analysis" field. If the design
genuinely needs no change, resend it unchanged, but say why in "analysis".`;

/** Pull the first balanced JSON object out of a model reply. */
export function extractJson(reply) {
  if (typeof reply !== 'string') throw new Error('empty reply');
  let text = reply.trim();
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) text = fence[1].trim();

  const start = text.indexOf('{');
  if (start === -1) throw new Error('no JSON object in reply');

  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') inString = true;
    else if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return JSON.parse(text.slice(start, i + 1));
    }
  }
  throw new Error('unterminated JSON object in reply');
}

function joinUrl(baseUrl, path) {
  return `${String(baseUrl).trim().replace(/\/+$/, '')}${path}`;
}

/**
 * A page served over https cannot call a plain http endpoint — browsers block
 * it as mixed content before the request is even sent, and the only error the
 * page gets is an unhelpful "Load failed" / "Failed to fetch". Detect that.
 */
export function needsRelay(baseUrl) {
  return typeof location !== 'undefined'
    && location.protocol === 'https:'
    && /^http:\/\//i.test(String(baseUrl || '').trim());
}

/** Resolve the URL actually fetched, routing via the server relay if asked. */
export function resolveEndpoint(config, path) {
  const direct = joinUrl(config.baseUrl, path);
  if (!config.useRelay) return direct;
  return `${location.origin}/relay/${direct}`;
}

/** POST to a team's chat-completions endpoint. */
export async function chatCompletion(config, messages, { signal, temperature = 0.9 } = {}) {
  const url = resolveEndpoint(config, '/chat/completions');

  let response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(config.apiKey ? { Authorization: `Bearer ${config.apiKey}` } : {}),
      },
      body: JSON.stringify({
        model: config.model,
        messages,
        temperature,
        // Generous: the agent is asked to show numeric working before the JSON.
        max_tokens: 2400,
      }),
      signal,
    });
  } catch (error) {
    if (signal?.aborted) throw error;
    // A network-level fetch rejection carries no detail by design, so explain
    // the two causes that actually produce it here.
    if (needsRelay(config.baseUrl) && !config.useRelay) {
      throw new Error(
        'Blocked as mixed content: this page is https and the endpoint is http. '
        + 'Tick "Route through server relay" on this team to fix it.',
      );
    }
    throw new Error(
      `Could not reach ${url} (${error.message}). Either the endpoint is down, or it `
      + 'is not sending CORS headers — tick "Route through server relay" to bypass CORS.',
    );
  }

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`HTTP ${response.status} ${response.statusText}${body ? ` — ${body.slice(0, 200)}` : ''}`);
  }

  const data = await response.json();
  const content = data?.choices?.[0]?.message?.content;
  if (typeof content !== 'string' || !content.trim()) {
    throw new Error('endpoint returned no message content');
  }
  return content;
}

/** Connection test for the "Connected!" badge under the model row. */
export async function testConnection(config) {
  const started = performance.now();
  const reply = await chatCompletion(
    config,
    [{ role: 'user', content: 'Reply with the single word: ready' }],
    { temperature: 0 },
  );
  return {
    ms: Math.round(performance.now() - started),
    sample: reply.trim().slice(0, 40),
  };
}

/* ---------------------------------------------------------------------- *
 * Offline designer — used when a team has no API key configured.
 * It draws from the same rule set, so an unconfigured team is a real
 * opponent rather than a placeholder.
 * ---------------------------------------------------------------------- */

const OFFLINE_WEAPONS = [
  {
    name: 'Sine Lance',
    endLateral: 0, endForward: 520,
    y: 'sin(t * pi) * 74 * (1 - 2 * mod(i, 2))',
    x: 't * d',
    damage: 26, count: 2, cooldown: 1.0, speed: 320, range: 520,
  },
  {
    name: 'Hook Volley',
    endLateral: -96, endForward: 540,
    y: 'sin(t * tau * 0.75) * 96 * (1 + i * 0.4)',
    x: 'd * smoothstep(0, 1, t)',
    damage: 19, count: 3, cooldown: 1.35, speed: 280, range: 540,
  },
  {
    name: 'Spiral Shard',
    endLateral: 0, endForward: 560,
    y: 'sin(t * tau * 2 + i * tau / n) * 48 * t',
    x: 't * d * (0.6 + 0.4 * t)',
    damage: 15, count: 4, cooldown: 1.5, speed: 380, range: 560,
  },
  {
    name: 'Parabola Mortar',
    endLateral: 0, endForward: 510,
    y: '-4 * 110 * t * (1 - t) * (1 - 2 * mod(i, 2))',
    x: 't * d',
    damage: 32, count: 1, cooldown: 1.6, speed: 240, range: 510,
  },
  {
    name: 'Boomerang Cutter',
    endLateral: 0, endForward: 575,
    // Overshoots to 1.15x range at the apex, then hooks back past the launcher.
    y: 'sin(t * tau) * 120',
    x: 'd * sin(t * pi) * 1.15',
    damage: 22, count: 2, cooldown: 1.25, speed: 300, range: 500,
  },
  {
    name: 'Lissajous Net',
    endLateral: 0, endForward: 580,
    y: 'sin(t * tau * 1.5 + i * 1.1) * 66',
    x: 't * d * (1 - 0.18 * sin(t * tau))',
    damage: 13, count: 5, cooldown: 1.7, speed: 340, range: 580,
  },
];

const OFFLINE_SHIELDS = [
  { name: 'Cardioid Ward', shape: '30 * (1 + 0.55 * cos(a))', capacity: 55, regen: 5, absorb: 0.55 },
  { name: 'Trefoil Baffle', shape: '26 + 12 * cos(a * 3)', capacity: 45, regen: 8, absorb: 0.45 },
  { name: 'Front Bastion', shape: '18 + 32 * bump(a, 0, 0.8)', capacity: 70, regen: 3, absorb: 0.7 },
  { name: 'Pulsing Aegis', shape: '28 + 10 * sin(t * 2 + a * 2)', capacity: 50, regen: 9, absorb: 0.5 },
  { name: 'Hex Plate', shape: '27 + 6 * cos(a * 6)', capacity: 60, regen: 6, absorb: 0.6 },
];

function pick(list, seed) {
  return list[Math.floor(Math.abs(seed)) % list.length];
}

/**
 * Build a firing solution the same way an agent is asked to: lead the target
 * over the flight time, then de-rotate by the curve's own end offset so the
 * END of the arc lands on the target rather than the start of it.
 */
function offlineAim(weapon) {
  const flight = 'hypot(tx - sx, ty - sy) / speed';
  const lead = `atan2(ty + tvy * ${flight} - sy, tx + tvx * ${flight} - sx)`;
  return `${lead} - atan2(${weapon.endLateral}, ${weapon.endForward})`;
}

export function offlineLoadout({ round, unitIndex, teamName }) {
  const seed = round * 7 + unitIndex * 3 + teamName.length;
  const w = pick(OFFLINE_WEAPONS, seed);
  const s = pick(OFFLINE_SHIELDS, seed * 2 + 1);
  return {
    callsign: `${teamName.slice(0, 8)}-${unitIndex + 1}`,
    doctrine: 'Offline heuristic designer (no API key configured for this team).',
    weapon: {
      name: w.name,
      damage: w.damage, count: w.count, cooldown: w.cooldown,
      speed: w.speed, range: w.range, radius: 5,
      aim: offlineAim(w),
      path: { x: w.x, y: w.y },
    },
    shield: { name: s.name, capacity: s.capacity, regen: s.regen, absorb: s.absorb, shape: s.shape },
  };
}

/** One request + parse, retrying once with the parse error fed back. */
async function askForDesign(config, messages, { signal, report, label }) {
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const reply = await chatCompletion(config, messages, { signal });
      return { spec: extractJson(reply), reply };
    } catch (error) {
      if (signal?.aborted) throw error;
      report(`${label}: ${error.message}`);
      if (attempt === 2) throw error;
      messages = [...messages,
        { role: 'assistant', content: '(unparseable reply)' },
        {
          role: 'user',
          content: `That failed: ${error.message}. Reply with ONLY the JSON object, no prose or fences.`,
        },
      ];
    }
  }
  throw new Error('unreachable');
}

/**
 * Design one unit's loadout.
 *
 * With `deep` enabled the agent designs, then critiques its own design against
 * the enemy's measured shield profile and resubmits — two passes of real
 * reasoning rather than one snap judgement. Falls back to the offline designer
 * if the team has no key or the endpoint fails.
 */
export async function designLoadout(config, context, { signal, log, deep = true } = {}) {
  const report = (msg) => log && log(msg);
  const label = `${context.teamName} unit ${context.unitIndex + 1}`;

  if (!config.apiKey || !config.baseUrl || !config.model) {
    const loadout = buildLoadout(offlineLoadout(context));
    loadout.origin = 'offline';
    return loadout;
  }

  try {
    const messages = [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: userPrompt(context) },
    ];

    const draft = await askForDesign(config, messages, { signal, report, label });
    let final = draft;
    let passes = 1;

    if (deep) {
      try {
        const critiqued = await askForDesign(config, [
          ...messages,
          { role: 'assistant', content: draft.reply },
          { role: 'user', content: CRITIQUE_PROMPT },
        ], { signal, report, label: `${label} (critique)` });
        final = critiqued;
        passes = 2;
      } catch {
        // The critique pass is a bonus — keep the draft if it fails.
        report(`${label}: critique pass failed, keeping the first design.`);
      }
    }

    const loadout = buildLoadout(final.spec);
    loadout.origin = 'llm';
    loadout.passes = passes;
    loadout.draftAnalysis = typeof draft.spec.analysis === 'string' ? draft.spec.analysis : '';
    loadout.raw = final.reply;
    return loadout;
  } catch (error) {
    if (signal?.aborted) throw error;
    const loadout = buildLoadout(offlineLoadout(context));
    loadout.origin = 'fallback';
    loadout.notes.unshift('Endpoint failed — the referee issued a stock loadout.');
    return loadout;
  }
}
