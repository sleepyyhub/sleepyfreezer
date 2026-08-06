/*
 * app.js — UI wiring, the round loop and the canvas renderer.
 */

import { designLoadout, needsRelay, resolveEndpoint, testConnection } from './agents.js';
import { ARENA, UNIT_RADIUS, advance, collectIntel, createBattle } from './sim.js';
import { MAX_DAMAGE, UNIT_MAX_HP } from './rules.js';

const TEAM_COLORS = ['#38bdf8', '#fb7185'];
const STORAGE_KEY = 'math-arena-teams-v1';

const DEFAULT_TEAMS = [
  { name: 'Team 1', baseUrl: 'http://106.54.43.21:3000/v1', apiKey: '', model: 'gpt-5.6-sol', enabled: true, useRelay: false },
  { name: 'Team 2', baseUrl: 'http://106.54.43.21:3000/v1', apiKey: '', model: 'gpt-5.6-sol', enabled: true, useRelay: false },
];

const teams = loadTeams();

// A saved http endpoint on an https page can only work through the relay.
for (const team of teams) {
  if (needsRelay(team.baseUrl)) team.useRelay = true;
}

const el = {
  config: document.getElementById('config'),
  canvas: document.getElementById('arena'),
  scoreboard: document.getElementById('scoreboard'),
  loadouts: document.getElementById('loadouts'),
  log: document.getElementById('log'),
  status: document.getElementById('status'),
  startBtn: document.getElementById('startBtn'),
  stopBtn: document.getElementById('stopBtn'),
  unitCount: document.getElementById('unitCount'),
  roundCount: document.getElementById('roundCount'),
  simSpeed: document.getElementById('simSpeed'),
};

const ctx = el.canvas.getContext('2d');

let battle = null;
let running = false;
let abortController = null;
let frameHandle = null;
let lastFrame = 0;
const wins = [0, 0];

/* ------------------------------- storage ------------------------------- */

function loadTeams() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (Array.isArray(saved) && saved.length === 2) {
      return saved.map((t, i) => ({ ...DEFAULT_TEAMS[i], ...t }));
    }
  } catch {
    /* corrupt or unavailable storage — fall through to defaults */
  }
  return structuredClone(DEFAULT_TEAMS);
}

function saveTeams() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(teams));
  } catch {
    /* storage disabled — config just won't persist */
  }
}

/* --------------------------------- UI ---------------------------------- */

function renderConfig() {
  el.config.innerHTML = '';
  teams.forEach((team, index) => {
    const card = document.createElement('div');
    card.className = 'team-card';
    card.dataset.team = String(index);
    card.innerHTML = `
      <div class="team-head">
        <input class="team-name" value="${escapeAttr(team.name)}" aria-label="Team name" />
        <button class="pill ${team.enabled ? '' : 'off'}" data-act="toggle">
          ${team.enabled ? 'Enabled' : 'Disabled'}
        </button>
      </div>

      <label class="field">
        <span>Base URL</span>
        <input type="text" data-field="baseUrl" value="${escapeAttr(team.baseUrl)}"
               placeholder="http://host:3000/v1" spellcheck="false" />
      </label>

      <label class="field">
        <span>API format</span>
        <select disabled><option>Chat completions (/chat/completions)</option></select>
      </label>

      <label class="field">
        <span>API key</span>
        <span class="key-row">
          <input type="password" data-field="apiKey" value="${escapeAttr(team.apiKey)}"
                 placeholder="leave empty to use the offline designer" spellcheck="false" />
          <button type="button" data-act="reveal" title="Show / hide key">&#128065;</button>
        </span>
      </label>

      <label class="field relay">
        <input type="checkbox" data-field="useRelay" ${team.useRelay ? 'checked' : ''} />
        <span class="relay-text">
          Route through server relay
          <em data-role="relay-hint"></em>
        </span>
      </label>

      <div class="field">
        <span>Model list</span>
        <div class="model-box">
          <div class="model-row">
            <input type="text" data-field="model" value="${escapeAttr(team.model)}"
                   placeholder="model-name" spellcheck="false" />
            <span class="badge">1M</span>
            <button type="button" class="test" data-act="test">Test</button>
          </div>
          <div class="conn" data-role="conn"></div>
        </div>
      </div>
    `;

    card.querySelector('.team-name').addEventListener('input', (e) => {
      team.name = e.target.value.trim() || `Team ${index + 1}`;
      saveTeams();
    });

    const relayHint = card.querySelector('[data-role="relay-hint"]');
    const relayToggle = card.querySelector('[data-field="useRelay"]');

    const refreshRelayHint = () => {
      if (needsRelay(team.baseUrl) && !team.useRelay) {
        relayHint.className = 'warn';
        relayHint.textContent =
          'Required — this page is https and your endpoint is http, so the browser will block the call.';
      } else if (team.useRelay) {
        relayHint.className = '';
        relayHint.textContent =
          `Calls go via ${location.origin}/relay/… — your API key passes through this server.`;
      } else {
        relayHint.className = '';
        relayHint.textContent = 'Off — the browser calls your endpoint directly. Turn on if you hit CORS.';
      }
    };

    card.querySelectorAll('[data-field]').forEach((input) => {
      const event = input.type === 'checkbox' ? 'change' : 'input';
      input.addEventListener(event, (e) => {
        const field = e.target.dataset.field;
        team[field] = e.target.type === 'checkbox' ? e.target.checked : e.target.value.trim();
        // A fresh http endpoint on an https page needs the relay; switch it on
        // rather than letting the user hit an opaque "Load failed".
        if (field === 'baseUrl' && needsRelay(team.baseUrl)) {
          team.useRelay = true;
          relayToggle.checked = true;
        }
        saveTeams();
        refreshRelayHint();
        card.querySelector('[data-role="conn"]').innerHTML = '';
      });
    });

    refreshRelayHint();

    card.querySelector('[data-act="reveal"]').addEventListener('click', () => {
      const input = card.querySelector('[data-field="apiKey"]');
      input.type = input.type === 'password' ? 'text' : 'password';
    });

    card.querySelector('[data-act="toggle"]').addEventListener('click', (e) => {
      team.enabled = !team.enabled;
      saveTeams();
      e.target.textContent = team.enabled ? 'Enabled' : 'Disabled';
      e.target.classList.toggle('off', !team.enabled);
    });

    card.querySelector('[data-act="test"]').addEventListener('click', async () => {
      const conn = card.querySelector('[data-role="conn"]');
      if (!team.apiKey) {
        conn.innerHTML = '<span class="bad">No API key — this team will use the offline designer.</span>';
        return;
      }
      conn.innerHTML = '<span class="wait">Connecting…</span>';
      try {
        const result = await testConnection(team);
        conn.innerHTML = `<span class="ok">Connected! ${result.ms}ms</span>`;
      } catch (error) {
        conn.innerHTML = `<span class="bad">${escapeHtml(error.message)}</span>`;
      }
    });

    el.config.appendChild(card);
  });
}

function log(text, kind = '') {
  const entry = document.createElement('div');
  entry.className = `entry ${kind}`.trim();
  entry.textContent = text;
  el.log.appendChild(entry);
  el.log.scrollTop = el.log.scrollHeight;
}

function setStatus(text) {
  el.status.textContent = text;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}
const escapeAttr = escapeHtml;

/* ----------------------------- loadout cards ---------------------------- */

const ORIGIN_LABEL = {
  llm: 'designed by model',
  offline: 'offline designer',
  fallback: 'referee fallback',
};

function renderLoadouts(all) {
  el.loadouts.innerHTML = '';
  all.forEach(({ team, loadout }) => {
    const card = document.createElement('div');
    card.className = 'loadout';
    card.style.borderLeftColor = TEAM_COLORS[team];
    const w = loadout.weapon;
    const s = loadout.shield;
    card.innerHTML = `
      <h3>
        <span>${escapeHtml(loadout.callsign)}</span>
        <span class="origin">${teams[team].name} · ${ORIGIN_LABEL[loadout.origin] || loadout.origin}</span>
      </h3>
      <p class="doctrine">${escapeHtml(loadout.doctrine)}</p>
      <dl>
        <dt>Weapon</dt><dd>${escapeHtml(w.name)} — ${w.damage.toFixed(0)} dmg ×${w.count},
          ${w.cooldown.toFixed(2)}s cd, ${w.speed.toFixed(0)}px/s, ${w.range.toFixed(0)}px range</dd>
        <dt>path.x</dt><dd><code>${escapeHtml(w.source.x)}</code></dd>
        <dt>path.y</dt><dd><code>${escapeHtml(w.source.y)}</code></dd>
        <dt>Bend</dt><dd>${w.curvature.toFixed(1)}px${w.homing > 0 ? ` · homing ${(w.homing * 100).toFixed(0)}%` : ''}</dd>
        <dt>Shield</dt><dd>${escapeHtml(s.name)} — ${s.capacity.toFixed(0)} pts,
          ${(s.absorb * 100).toFixed(0)}% absorb, +${s.regen.toFixed(1)}/s</dd>
        <dt>shape</dt><dd><code>${escapeHtml(s.source)}</code></dd>
      </dl>
      ${loadout.notes.length
        ? `<ul class="notes">${loadout.notes.map((n) => `<li>${escapeHtml(n)}</li>`).join('')}</ul>`
        : ''}
    `;
    el.loadouts.appendChild(card);
  });
}

function renderScoreboard() {
  if (!battle) return;
  el.scoreboard.innerHTML = '';
  for (const unit of battle.units) {
    const div = document.createElement('div');
    div.className = `score${unit.alive ? '' : ' dead'}`;
    div.style.borderLeftColor = TEAM_COLORS[unit.team];
    const shield = unit.loadout.shield;
    const shieldPct = shield.capacity > 0 ? (unit.shieldCharge / shield.capacity) * 100 : 0;
    div.innerHTML = `
      <div class="name"><span>${escapeHtml(unit.callsign)}</span><span>${unit.hp.toFixed(0)} HP</span></div>
      <div class="meta">${escapeHtml(unit.loadout.weapon.name)} · dealt ${unit.damageDealt.toFixed(0)} · took ${unit.hitsTaken} hits</div>
      <div class="bar"><i style="width:${(unit.hp / UNIT_MAX_HP) * 100}%;background:${TEAM_COLORS[unit.team]}"></i></div>
      <div class="bar shield"><i style="width:${shieldPct}%;background:#e2e8f0"></i></div>
    `;
    el.scoreboard.appendChild(div);
  }
}

/* ------------------------------- rendering ------------------------------ */

function draw() {
  ctx.clearRect(0, 0, ARENA.width, ARENA.height);

  // Grid — this is a math arena, so it gets graph paper.
  ctx.strokeStyle = 'rgba(255,255,255,0.045)';
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let x = 0; x <= ARENA.width; x += 40) { ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, ARENA.height); }
  for (let y = 0; y <= ARENA.height; y += 40) { ctx.moveTo(0, y + 0.5); ctx.lineTo(ARENA.width, y + 0.5); }
  ctx.stroke();

  if (!battle) {
    ctx.fillStyle = '#6b7280';
    ctx.font = '15px ui-sans-serif, system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('Press "Start battle" to have both teams design their loadouts.', ARENA.width / 2, ARENA.height / 2);
    ctx.textAlign = 'left';
    return;
  }

  for (const unit of battle.units) {
    if (unit.alive) drawShield(unit);
  }
  for (const p of battle.projectiles) {
    drawProjectile(p);
  }
  for (const unit of battle.units) {
    drawUnit(unit);
  }

  ctx.fillStyle = '#9aa1a8';
  ctx.font = '12px ui-monospace, Menlo, monospace';
  ctx.fillText(`t = ${battle.time.toFixed(1)}s`, 12, 20);

  if (battle.over) {
    ctx.fillStyle = 'rgba(15,17,19,0.72)';
    ctx.fillRect(0, ARENA.height / 2 - 46, ARENA.width, 92);
    ctx.textAlign = 'center';
    ctx.fillStyle = battle.winner === null ? '#e7e9ea' : TEAM_COLORS[battle.winner];
    ctx.font = '600 26px ui-sans-serif, system-ui, sans-serif';
    ctx.fillText(
      battle.winner === null ? 'Draw' : `${teams[battle.winner].name} wins the round`,
      ARENA.width / 2, ARENA.height / 2 + 2,
    );
    ctx.fillStyle = '#9aa1a8';
    ctx.font = '13px ui-sans-serif, system-ui, sans-serif';
    ctx.fillText(battle.reason, ARENA.width / 2, ARENA.height / 2 + 26);
    ctx.textAlign = 'left';
  }
}

function drawShield(unit) {
  const shield = unit.loadout.shield;
  if (shield.capacity <= 0) return;
  const strength = unit.shieldCharge / shield.capacity;
  if (strength <= 0.01) return;

  ctx.save();
  ctx.translate(unit.x, unit.y);
  ctx.rotate(unit.facing);
  ctx.beginPath();
  const STEPS = 90;
  for (let s = 0; s <= STEPS; s++) {
    const a = (s / STEPS) * Math.PI * 2;
    const r = shield.radiusAt(a, battle.time);
    const px = Math.cos(a) * r;
    const py = Math.sin(a) * r;
    if (s === 0) ctx.moveTo(px, py);
    else ctx.lineTo(px, py);
  }
  ctx.closePath();
  ctx.fillStyle = `rgba(226,232,240,${0.05 + strength * 0.09})`;
  ctx.fill();
  ctx.strokeStyle = `rgba(226,232,240,${0.2 + strength * 0.55})`;
  ctx.lineWidth = 1.5;
  ctx.stroke();
  ctx.restore();
}

function drawProjectile(p) {
  const color = TEAM_COLORS[p.team];
  ctx.strokeStyle = color;
  ctx.globalAlpha = 0.45;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.moveTo(p.prevX, p.prevY);
  ctx.lineTo(p.x, p.y);
  ctx.stroke();
  ctx.globalAlpha = 1;

  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(p.x, p.y, p.weapon.radius, 0, Math.PI * 2);
  ctx.fill();
}

function drawUnit(unit) {
  const color = TEAM_COLORS[unit.team];
  ctx.save();
  ctx.globalAlpha = unit.alive ? 1 : 0.28;

  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(unit.x, unit.y, UNIT_RADIUS, 0, Math.PI * 2);
  ctx.fill();

  if (unit.alive) {
    ctx.strokeStyle = 'rgba(0,0,0,0.5)';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(unit.x, unit.y);
    ctx.lineTo(unit.x + Math.cos(unit.facing) * UNIT_RADIUS, unit.y + Math.sin(unit.facing) * UNIT_RADIUS);
    ctx.stroke();
  }

  // HP pip bar above the unit — two-hit survival is the point, so show it.
  const barWidth = 34;
  ctx.fillStyle = 'rgba(0,0,0,0.5)';
  ctx.fillRect(unit.x - barWidth / 2, unit.y - UNIT_RADIUS - 11, barWidth, 4);
  ctx.fillStyle = color;
  ctx.fillRect(unit.x - barWidth / 2, unit.y - UNIT_RADIUS - 11, barWidth * (unit.hp / UNIT_MAX_HP), 4);

  ctx.fillStyle = '#cbd5e1';
  ctx.font = '10px ui-sans-serif, system-ui, sans-serif';
  ctx.textAlign = 'center';
  ctx.fillText(unit.callsign, unit.x, unit.y + UNIT_RADIUS + 14);
  ctx.textAlign = 'left';
  ctx.restore();
}

/* ------------------------------ round loop ------------------------------ */

async function designTeam(teamIndex, unitCount, round, enemyIntel, refereeNotes) {
  const team = teams[teamIndex];
  const jobs = [];
  for (let i = 0; i < unitCount; i++) {
    jobs.push(designLoadout(
      team,
      {
        round,
        teamName: team.name,
        unitIndex: i,
        unitCount,
        enemyIntel,
        refereeNotes: refereeNotes?.[i],
      },
      { signal: abortController.signal, log: (m) => log(m, 'warn') },
    ));
  }
  return Promise.all(jobs);
}

function runBattleFrame(timestamp) {
  if (!running) return;
  const dt = lastFrame ? (timestamp - lastFrame) / 1000 : 0;
  lastFrame = timestamp;

  advance(battle, dt, parseFloat(el.simSpeed.value));
  draw();
  renderScoreboard();

  while (battle.events.length) {
    log(battle.events.shift().text, 'warn');
  }

  if (battle.over) {
    frameHandle = null;
    return;
  }
  frameHandle = requestAnimationFrame(runBattleFrame);
}

function playBattle() {
  return new Promise((resolve) => {
    lastFrame = 0;
    const tick = (timestamp) => {
      runBattleFrame(timestamp);
      if (!running || battle.over) resolve();
      else requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

async function startBattle() {
  running = true;
  abortController = new AbortController();
  el.startBtn.disabled = true;
  el.stopBtn.disabled = false;
  el.log.innerHTML = '';
  wins[0] = 0;
  wins[1] = 0;

  const unitCount = Math.max(1, Math.min(4, parseInt(el.unitCount.value, 10) || 3));
  const roundCount = Math.max(1, Math.min(10, parseInt(el.roundCount.value, 10) || 3));

  for (const [i, team] of teams.entries()) {
    if (!team.enabled) {
      log(`${team.name} is disabled — its units will use the offline designer.`, 'warn');
    } else if (!team.apiKey) {
      log(`${team.name} has no API key — using the offline designer.`, 'warn');
    } else {
      log(`${team.name}: ${team.model} @ ${resolveEndpoint(team, '/chat/completions')}`);
    }
    void i;
  }

  let intel = [null, null];
  let notes = [null, null];

  try {
    for (let round = 1; round <= roundCount && running; round++) {
      log(`— Round ${round} — agents designing loadouts…`, 'head');
      setStatus(`Round ${round}/${roundCount}: designing loadouts…`);

      const [aLoadouts, bLoadouts] = await Promise.all([
        designTeam(0, unitCount, round, intel[1], notes[0]),
        designTeam(1, unitCount, round, intel[0], notes[1]),
      ]);
      if (!running) break;

      renderLoadouts([
        ...aLoadouts.map((loadout) => ({ team: 0, loadout })),
        ...bLoadouts.map((loadout) => ({ team: 1, loadout })),
      ]);

      for (const [teamIndex, loadouts] of [[0, aLoadouts], [1, bLoadouts]]) {
        for (const loadout of loadouts) {
          for (const note of loadout.notes) log(`${teams[teamIndex].name} · ${note}`, 'warn');
        }
      }

      battle = createBattle(aLoadouts, bLoadouts);
      setStatus(`Round ${round}/${roundCount}: fighting…`);
      await playBattle();
      if (!running) break;

      if (battle.winner !== null) wins[battle.winner]++;
      log(
        `Round ${round} result: ${battle.winner === null ? 'draw' : `${teams[battle.winner].name} wins`} — ${battle.reason}`,
        'head',
      );

      intel = [collectIntel(battle, 0), collectIntel(battle, 1)];
      notes = [
        aLoadouts.map((l) => l.notes),
        bLoadouts.map((l) => l.notes),
      ];
    }

    if (running) {
      const overall = wins[0] === wins[1]
        ? 'Match drawn'
        : `${teams[wins[0] > wins[1] ? 0 : 1].name} takes the match`;
      log(`${overall} — ${teams[0].name} ${wins[0]} : ${wins[1]} ${teams[1].name}`, 'head');
      setStatus(`${overall} (${wins[0]}–${wins[1]}).`);
    }
  } catch (error) {
    if (!abortController.signal.aborted) {
      log(`Battle aborted: ${error.message}`, 'err');
      setStatus(`Error: ${error.message}`);
    }
  } finally {
    running = false;
    el.startBtn.disabled = false;
    el.stopBtn.disabled = true;
    if (frameHandle) cancelAnimationFrame(frameHandle);
  }
}

function stopBattle() {
  running = false;
  abortController?.abort();
  setStatus('Stopped.');
  el.startBtn.disabled = false;
  el.stopBtn.disabled = true;
}

el.startBtn.addEventListener('click', startBattle);
el.stopBtn.addEventListener('click', stopBattle);

renderConfig();
draw();
log(`Referee ready. Damage cap ${MAX_DAMAGE} of ${UNIT_MAX_HP} HP — two hits can never kill.`);
