/*
 * app.js — UI wiring, the match loop, the canvas renderer and the recorder.
 */

import { designLoadout, needsRelay, resolveEndpoint, testConnection } from './agents.js';
import {
  ANNOUNCE_SECONDS,
  ARENA,
  UNIT_RADIUS,
  advance,
  beginRound,
  collectIntel,
  createMatch,
  decideOnPoints,
  pickAttacker,
  setLoadout,
} from './sim.js';
import { MAX_DAMAGE, UNIT_MAX_HP } from './rules.js';
import { patchWebmDuration } from './webm.js';

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
  downloadBtn: document.getElementById('downloadBtn'),
  unitCount: document.getElementById('unitCount'),
  roundCount: document.getElementById('roundCount'),
  simSpeed: document.getElementById('simSpeed'),
  deepDesign: document.getElementById('deepDesign'),
};

const ctx = el.canvas.getContext('2d');

let match = null;
let running = false;
let abortController = null;
let overlayText = '';
let roundResolver = null;

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

/* ---------------------------- loadout panel ----------------------------- */

const ORIGIN_LABEL = {
  llm: 'designed by model',
  offline: 'offline designer',
  fallback: 'referee fallback',
};

const loadoutHistory = [];

function pushLoadoutCard(team, loadout, round, isAttacker) {
  loadoutHistory.unshift({ team, loadout, round, isAttacker });
  renderLoadouts();
}

function renderLoadouts() {
  el.loadouts.innerHTML = '';
  for (const { team, loadout, round, isAttacker } of loadoutHistory) {
    const card = document.createElement('div');
    card.className = 'loadout';
    card.style.borderLeftColor = TEAM_COLORS[team];
    const w = loadout.weapon;
    const s = loadout.shield;
    const passLabel = loadout.passes === 2 ? ' · 2-pass' : '';
    card.innerHTML = `
      <h3>
        <span>${escapeHtml(loadout.callsign)}${isAttacker ? ' <em class="atk">attacker</em>' : ''}</span>
        <span class="origin">R${round} · ${teams[team].name} · ${ORIGIN_LABEL[loadout.origin] || loadout.origin}${passLabel}</span>
      </h3>
      <p class="doctrine">${escapeHtml(loadout.doctrine)}</p>
      ${loadout.analysis
        ? `<details class="analysis"><summary>Agent's reasoning</summary><p>${escapeHtml(loadout.analysis)}</p></details>`
        : ''}
      <dl>
        <dt>Weapon</dt><dd>${escapeHtml(w.name)} — ${w.damage.toFixed(0)} dmg ×${w.count},
          ${w.speed.toFixed(0)}px/s, ${w.range.toFixed(0)}px range</dd>
        <dt>path.x</dt><dd><code>${escapeHtml(w.source.x)}</code></dd>
        <dt>path.y</dt><dd><code>${escapeHtml(w.source.y)}</code></dd>
        <dt>aim</dt><dd>${w.aimed
          ? `<code>${escapeHtml(w.source.aim)}</code>`
          : '<span class="unaimed">no firing solution — referee aimed it</span>'}</dd>
        <dt>Bend</dt><dd>${w.curvature.toFixed(1)}px</dd>
        <dt>Shield</dt><dd>${escapeHtml(s.name)} — ${s.capacity.toFixed(0)} pts,
          ${(s.absorb * 100).toFixed(0)}% absorb, +${s.regen.toFixed(1)}/s</dd>
        <dt>shape</dt><dd><code>${escapeHtml(s.source)}</code></dd>
      </dl>
      ${loadout.notes.length
        ? `<ul class="notes">${loadout.notes.map((n) => `<li>${escapeHtml(n)}</li>`).join('')}</ul>`
        : ''}
    `;
    el.loadouts.appendChild(card);
  }
}

function renderScoreboard() {
  if (!match) return;
  el.scoreboard.innerHTML = '';
  const attackerIds = new Set(match.turnQueue);
  for (const unit of match.units) {
    const div = document.createElement('div');
    div.className = `score${unit.alive ? '' : ' dead'}${attackerIds.has(unit.id) ? ' attacking' : ''}`;
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
  // Paint the background rather than leaving it to CSS: captureStream records
  // the canvas bitmap only, so a CSS-only background records as transparent
  // and the exported video comes out on white.
  ctx.fillStyle = '#0f1113';
  ctx.fillRect(0, 0, ARENA.width, ARENA.height);

  ctx.strokeStyle = 'rgba(255,255,255,0.045)';
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let x = 0; x <= ARENA.width; x += 40) { ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, ARENA.height); }
  for (let y = 0; y <= ARENA.height; y += 40) { ctx.moveTo(0, y + 0.5); ctx.lineTo(ARENA.width, y + 0.5); }
  ctx.stroke();

  if (!match) {
    ctx.fillStyle = '#6b7280';
    ctx.font = '15px ui-sans-serif, system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText(overlayText || 'Press "Start match" — one bot per team attacks each round.',
      ARENA.width / 2, ARENA.height / 2);
    ctx.textAlign = 'left';
    return;
  }

  for (const unit of match.units) {
    if (unit.alive) drawShield(unit);
  }
  for (const p of match.projectiles) drawProjectile(p);
  for (const unit of match.units) drawUnit(unit);

  drawHud();
  if (match.announcement) drawAnnouncement(match.announcement);
  if (overlayText) drawOverlay(overlayText);
  if (match.over) drawResult();
}

function drawHud() {
  ctx.fillStyle = '#9aa1a8';
  ctx.font = '12px ui-monospace, Menlo, monospace';
  ctx.fillText(`round ${match.round}   t = ${match.time.toFixed(1)}s`, 12, 20);

  for (const [team, x] of [[0, 12], [1, ARENA.width - 12]]) {
    ctx.textAlign = team === 0 ? 'left' : 'right';
    ctx.fillStyle = TEAM_COLORS[team];
    ctx.font = '600 13px ui-sans-serif, system-ui, sans-serif';
    ctx.fillText(teams[team].name, x, 40);
  }
  ctx.textAlign = 'left';
}

/** Wrap `text` to `maxWidth`, returning the lines. */
function wrapText(text, maxWidth) {
  const words = String(text).split(/\s+/);
  const lines = [];
  let line = '';
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (ctx.measureText(candidate).width > maxWidth && line) {
      lines.push(line);
      line = word;
    } else {
      line = candidate;
    }
  }
  if (line) lines.push(line);
  return lines;
}

/**
 * The pre-attack declaration: who is firing, what they call it, and the
 * equation behind it. This is the moment the match is about, so it gets the
 * centre of the screen and enough time to read.
 */
function drawAnnouncement(a) {
  const color = TEAM_COLORS[a.team];
  const width = ARENA.width - 140;
  const x = 70;

  ctx.font = '600 17px ui-monospace, SFMono-Regular, Menlo, monospace';
  const eqLines = wrapText(`y(t) = ${a.equation}`, width - 48);

  ctx.font = '13px ui-monospace, SFMono-Regular, Menlo, monospace';
  const aimLines = a.aimed
    ? wrapText(`aim = ${a.aim}`, width - 48)
    : ['aim = (none supplied — referee is pointing it straight at the target)'];
  ctx.font = '13px ui-sans-serif, system-ui, sans-serif';
  const docLines = a.doctrine ? wrapText(a.doctrine, width - 48) : [];

  // Leaves clear space under the last line for the countdown bar.
  const height = 130 + eqLines.length * 24 + aimLines.length * 17 + docLines.length * 18;
  const y = (ARENA.height - height) / 2;

  ctx.fillStyle = 'rgba(12,14,16,0.93)';
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.roundRect(x, y, width, height, 12);
  ctx.fill();
  ctx.stroke();

  ctx.textAlign = 'center';
  const centre = ARENA.width / 2;

  ctx.fillStyle = color;
  ctx.font = '600 13px ui-sans-serif, system-ui, sans-serif';
  ctx.fillText(`${a.callsign} attacks with`, centre, y + 30);

  ctx.fillStyle = '#f1f5f9';
  ctx.font = '700 26px ui-sans-serif, system-ui, sans-serif';
  ctx.fillText(a.weaponName, centre, y + 62);

  ctx.fillStyle = '#a5f3c4';
  ctx.font = '600 17px ui-monospace, SFMono-Regular, Menlo, monospace';
  eqLines.forEach((line, i) => ctx.fillText(line, centre, y + 94 + i * 24));

  // The firing solution — the trigonometry the agent had to do itself.
  ctx.fillStyle = a.aimed ? '#7dd3fc' : '#fbbf24';
  ctx.font = '13px ui-monospace, SFMono-Regular, Menlo, monospace';
  const aimTop = y + 96 + eqLines.length * 24;
  aimLines.forEach((line, i) => ctx.fillText(line, centre, aimTop + i * 17));

  ctx.fillStyle = '#94a3b8';
  ctx.font = '13px ui-sans-serif, system-ui, sans-serif';
  const docTop = aimTop + aimLines.length * 17 + 8;
  docLines.forEach((line, i) => ctx.fillText(line, centre, docTop + i * 18));

  // Countdown bar — shows exactly when the shot goes out.
  const progress = 1 - Math.max(match.phaseTimer, 0) / ANNOUNCE_SECONDS;
  ctx.fillStyle = 'rgba(255,255,255,0.12)';
  ctx.fillRect(x + 24, y + height - 14, width - 48, 4);
  ctx.fillStyle = color;
  ctx.fillRect(x + 24, y + height - 14, (width - 48) * progress, 4);

  ctx.textAlign = 'left';
}

function drawOverlay(text) {
  ctx.fillStyle = 'rgba(12,14,16,0.78)';
  ctx.fillRect(0, ARENA.height / 2 - 34, ARENA.width, 68);
  ctx.textAlign = 'center';
  ctx.fillStyle = '#e2e8f0';
  ctx.font = '600 18px ui-sans-serif, system-ui, sans-serif';
  ctx.fillText(text, ARENA.width / 2, ARENA.height / 2 + 6);
  ctx.textAlign = 'left';
}

function drawResult() {
  ctx.fillStyle = 'rgba(15,17,19,0.75)';
  ctx.fillRect(0, ARENA.height / 2 - 46, ARENA.width, 92);
  ctx.textAlign = 'center';
  ctx.fillStyle = match.winner === null ? '#e7e9ea' : TEAM_COLORS[match.winner];
  ctx.font = '600 26px ui-sans-serif, system-ui, sans-serif';
  ctx.fillText(
    match.winner === null ? 'Draw' : `${teams[match.winner].name} wins`,
    ARENA.width / 2, ARENA.height / 2 + 2,
  );
  ctx.fillStyle = '#9aa1a8';
  ctx.font = '13px ui-sans-serif, system-ui, sans-serif';
  ctx.fillText(match.reason, ARENA.width / 2, ARENA.height / 2 + 26);
  ctx.textAlign = 'left';
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
    const r = shield.radiusAt(a, match.time);
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
  const isAttacker = match.turnQueue[match.turnIndex] === unit.id && !match.roundComplete;

  ctx.save();
  ctx.globalAlpha = unit.alive ? 1 : 0.28;

  if (isAttacker && unit.alive) {
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    ctx.arc(unit.x, unit.y, UNIT_RADIUS + 9, 0, Math.PI * 2);
    ctx.stroke();
    ctx.setLineDash([]);
  }

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

/* ------------------------------- recorder ------------------------------- */

const recording = {
  recorder: null,
  chunks: [],
  url: null,
  startedAt: 0,
  supported: typeof MediaRecorder !== 'undefined',
};

function pickMimeType() {
  const candidates = [
    'video/webm;codecs=vp9',
    'video/webm;codecs=vp8',
    'video/webm',
    'video/mp4',
  ];
  return candidates.find((type) => MediaRecorder.isTypeSupported(type)) || '';
}

function startRecording() {
  if (!recording.supported || !el.canvas.captureStream) {
    log('This browser cannot record the canvas — the match will play without a recording.', 'warn');
    return;
  }
  if (recording.url) {
    URL.revokeObjectURL(recording.url);
    recording.url = null;
  }
  recording.chunks = [];
  el.downloadBtn.disabled = true;

  try {
    const stream = el.canvas.captureStream(30);
    const mimeType = pickMimeType();
    recording.recorder = new MediaRecorder(stream, mimeType ? { mimeType, videoBitsPerSecond: 4_000_000 } : {});
    recording.recorder.ondataavailable = (e) => {
      if (e.data && e.data.size) recording.chunks.push(e.data);
    };
    recording.recorder.start(1000);
    recording.startedAt = performance.now();
  } catch (error) {
    recording.recorder = null;
    log(`Recording unavailable: ${error.message}`, 'warn');
  }
}

function stopRecording() {
  return new Promise((resolve) => {
    if (!recording.recorder || recording.recorder.state === 'inactive') {
      resolve();
      return;
    }
    recording.recorder.onstop = async () => {
      const type = recording.recorder.mimeType || 'video/webm';
      const durationMs = performance.now() - recording.startedAt;
      let blob = new Blob(recording.chunks, { type });

      // MediaRecorder omits the duration because it is recording live, which
      // leaves players showing 0:00 and unable to seek. We know it now.
      if (type.includes('webm')) {
        try {
          const patched = patchWebmDuration(new Uint8Array(await blob.arrayBuffer()), durationMs);
          blob = new Blob([patched], { type });
        } catch (error) {
          log(`Could not write the video duration (${error.message}); it will still play.`, 'warn');
        }
      }

      recording.url = URL.createObjectURL(blob);
      recording.extension = type.includes('mp4') ? 'mp4' : 'webm';
      el.downloadBtn.disabled = false;
      log(
        `Recording ready — ${(blob.size / 1024 / 1024).toFixed(1)} MB, `
        + `${(durationMs / 1000).toFixed(0)}s. Use "Download recording".`,
        'head',
      );
      resolve();
    };
    recording.recorder.stop();
  });
}

el.downloadBtn.addEventListener('click', () => {
  if (!recording.url) return;
  const link = document.createElement('a');
  link.href = recording.url;
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  link.download = `math-arena-${stamp}.${recording.extension || 'webm'}`;
  link.click();
});

/* ------------------------------ match loop ------------------------------ */

// One render loop for the whole session, so the recording captures the
// thinking phases and the result screen too, not just the shooting.
function renderLoop(timestamp) {
  const dt = renderLoop.last ? (timestamp - renderLoop.last) / 1000 : 0;
  renderLoop.last = timestamp;

  if (match && running && !match.roundComplete && !match.over) {
    advance(match, dt, parseFloat(el.simSpeed.value));
    while (match.events.length) {
      const event = match.events.shift();
      const kind = { kill: 'warn', announce: 'head', aim: 'aim', warn: 'warn' }[event.kind] || '';
      log(event.text, kind);
    }
    if ((match.roundComplete || match.over) && roundResolver) {
      const resolve = roundResolver;
      roundResolver = null;
      resolve();
    }
  }

  draw();
  renderScoreboard();
  requestAnimationFrame(renderLoop);
}

function waitForRound() {
  return new Promise((resolve) => {
    if (!match || match.roundComplete || match.over) {
      resolve();
      return;
    }
    roundResolver = resolve;
  });
}

async function design(teamIndex, context) {
  return designLoadout(teams[teamIndex], context, {
    signal: abortController.signal,
    log: (m) => log(m, 'warn'),
    deep: el.deepDesign.checked,
  });
}

async function startMatch() {
  running = true;
  abortController = new AbortController();
  el.startBtn.disabled = true;
  el.stopBtn.disabled = false;
  el.log.innerHTML = '';
  loadoutHistory.length = 0;
  renderLoadouts();
  match = null;

  const unitCount = Math.max(1, Math.min(4, parseInt(el.unitCount.value, 10) || 3));
  const roundCount = Math.max(1, Math.min(12, parseInt(el.roundCount.value, 10) || 4));

  for (const team of teams) {
    if (!team.enabled) log(`${team.name} is disabled — using the offline designer.`, 'warn');
    else if (!team.apiKey) log(`${team.name} has no API key — using the offline designer.`, 'warn');
    else log(`${team.name}: ${team.model} @ ${resolveEndpoint(team, '/chat/completions')}`);
  }
  if (el.deepDesign.checked) log('Deep design on — each agent drafts, critiques its own build, then resubmits.');

  try {
    // Opening loadouts for every unit.
    overlayText = 'Agents designing their opening loadouts…';
    setStatus('Designing opening loadouts…');
    log('— Setup — every unit designs its opening loadout.', 'head');

    const openings = await Promise.all([0, 1].map((team) => Promise.all(
      Array.from({ length: unitCount }, (_, i) => design(team, {
        round: 1,
        teamName: teams[team].name,
        unitIndex: i,
        unitCount,
        isAttacker: i === 0,
      })),
    )));
    if (!running) return;

    match = createMatch(openings[0], openings[1]);
    openings.forEach((list, team) => list.forEach((l) => pushLoadoutCard(team, l, 0, false)));
    for (const [team, list] of openings.entries()) {
      for (const loadout of list) {
        for (const note of loadout.notes) log(`${teams[team].name} · ${note}`, 'warn');
      }
    }

    overlayText = '';
    startRecording();

    for (let round = 1; round <= roundCount && running && !match.over; round++) {
      const attackers = [0, 1].map((team) => pickAttacker(match, team, round));
      if (attackers.some((a) => !a)) break;

      // Only the attackers redesign — they are the ones who get to act.
      if (round > 1) {
        overlayText = `Round ${round} — attackers rethinking their designs…`;
        setStatus(`Round ${round}/${roundCount}: attackers designing…`);
        log(`— Round ${round} — ${attackers[0].callsign} and ${attackers[1].callsign} design their attacks.`, 'head');

        const designs = await Promise.all(attackers.map((attacker, team) => design(team, {
          round,
          teamName: teams[team].name,
          unitIndex: attacker.index,
          unitCount,
          isAttacker: true,
          enemyIntel: collectIntel(match, team === 0 ? 1 : 0),
          allyIntel: collectIntel(match, team),
          refereeNotes: attacker.loadout.notes,
        })));
        if (!running) return;

        designs.forEach((loadout, team) => {
          setLoadout(match, attackers[team].id, loadout);
          pushLoadoutCard(team, loadout, round, true);
          for (const note of loadout.notes) log(`${teams[team].name} · ${note}`, 'warn');
        });
        overlayText = '';
      } else {
        log('— Round 1 — opening attacks.', 'head');
      }

      setStatus(`Round ${round}/${roundCount}: ${attackers[0].callsign} vs ${attackers[1].callsign}`);
      beginRound(match, round, attackers.map((a) => a.id));
      await waitForRound();
      if (!running) return;
    }

    if (running) {
      if (!match.over) decideOnPoints(match);
      log(`Match over — ${match.winner === null ? 'draw' : `${teams[match.winner].name} wins`}. ${match.reason}`, 'head');
      setStatus(`${match.winner === null ? 'Draw' : `${teams[match.winner].name} wins`} — ${match.reason}`);
      draw();
      await stopRecording();
    }
  } catch (error) {
    if (!abortController.signal.aborted) {
      log(`Match aborted: ${error.message}`, 'err');
      setStatus(`Error: ${error.message}`);
    }
  } finally {
    running = false;
    overlayText = '';
    el.startBtn.disabled = false;
    el.stopBtn.disabled = true;
    if (recording.recorder && recording.recorder.state !== 'inactive') await stopRecording();
  }
}

function stopMatch() {
  running = false;
  abortController?.abort();
  if (roundResolver) {
    const resolve = roundResolver;
    roundResolver = null;
    resolve();
  }
  setStatus('Stopped.');
  el.startBtn.disabled = false;
  el.stopBtn.disabled = true;
  stopRecording();
}

el.startBtn.addEventListener('click', startMatch);
el.stopBtn.addEventListener('click', stopMatch);

renderConfig();
requestAnimationFrame(renderLoop);
log(`Referee ready. Damage cap ${MAX_DAMAGE} of ${UNIT_MAX_HP} HP — two hits can never kill.`);
log('One bot per team attacks each round, declaring its weapon and equation first.');
