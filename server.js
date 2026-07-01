'use strict';
/* ════════════════════════════════════════════════════════════════════
   SLEEPY ROYALE — lightweight party / lobby / relay server

   Architecture (deliberately minimal):
   - One Node process serves both the game client (index.html over
     HTTP) and the realtime socket (WebSocket via `ws`) on ONE port,
     so the client can always connect to location.host.
   - Parties are in-memory rooms keyed by a short 4-char code.
   - The server is authoritative for LOBBY state only (roster, host,
     mode, teams). In-match it is a message RELAY: each client owns
     its player (position, hp) and broadcasts state at ~15 Hz; damage
     is routed to the victim's client, which applies it and reports
     its new hp in the next state packet. The map, chest loot and
     storm are derived deterministically from a shared seed, so they
     need no per-tick sync. This keeps the server tiny and stateless
     per match — good enough for friends-and-family scale; swap the
     relay for server-side simulation if you need cheat resistance.

   Run:  npm install && npm start   (then open http://<host>:8080)
   ════════════════════════════════════════════════════════════════════ */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8080;

/* ---------- static file server (just index.html) ---------- */
const httpServer = http.createServer((req, res) => {
  if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
    fs.readFile(path.join(__dirname, 'index.html'), (err, data) => {
      if (err) { res.writeHead(500); res.end('index.html not found'); return; }
      // no-store: iPad Safari and home-screen apps aggressively cache,
      // which otherwise keeps players on stale builds after updates
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(data);
    });
  } else if (req.url === '/favicon.ico') {
    res.writeHead(204); res.end(); // no icon, but keep the console clean
  } else {
    res.writeHead(404); res.end('Not found');
  }
});

/* ---------- party bookkeeping ---------- */
// code -> { code, hostId, mode, started, players: Map<id, {ws,name,look,team}> }
const parties = new Map();
let nextId = 1;

// Short, unambiguous party codes (no 0/O/1/I).
const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function makeCode() {
  let code;
  do {
    code = '';
    for (let i = 0; i < 4; i++) code += CODE_CHARS[(Math.random() * CODE_CHARS.length) | 0];
  } while (parties.has(code));
  return code;
}

function send(ws, obj) { if (ws.readyState === 1) ws.send(JSON.stringify(obj)); }

// Broadcast to every member of a party, optionally skipping one id.
function broadcast(party, obj, exceptId = null) {
  for (const [id, p] of party.players) if (id !== exceptId) send(p.ws, obj);
}

// Serializable lobby snapshot sent on every roster/mode/team change.
function lobbyPayload(party) {
  return {
    code: party.code,
    hostId: party.hostId,
    mode: party.mode,
    players: [...party.players].map(([id, p]) => ({ id, name: p.name, look: p.look, team: p.team })),
  };
}
function pushLobby(party) { broadcast(party, { t: 'lobby', party: lobbyPayload(party) }); }

// Default team for a new member: solos = own id; team modes = balance A/B.
function autoTeam(party) {
  if (party.mode === 'solos') return 'S';
  let a = 0, b = 0;
  for (const [, p] of party.players) (p.team === 'A' ? a++ : b++);
  return a <= b ? 'A' : 'B';
}

/* ---------- websocket handling ---------- */
const wss = new WebSocketServer({ server: httpServer });

wss.on('connection', ws => {
  ws.id = 'p' + nextId++;
  ws.partyCode = null;

  ws.on('message', raw => {
    let m;
    try { m = JSON.parse(raw); } catch (e) { return; }
    const party = ws.partyCode ? parties.get(ws.partyCode) : null;

    switch (m.t) {
      /* ----- party lifecycle ----- */
      case 'create_party': {
        const code = makeCode();
        const p = { code, hostId: ws.id, mode: 'solos', started: false, players: new Map() };
        p.players.set(ws.id, { ws, name: cleanName(m.name), look: cleanLook(m.look), team: 'S' });
        parties.set(code, p);
        ws.partyCode = code;
        send(ws, { t: 'joined', selfId: ws.id, party: lobbyPayload(p) });
        break;
      }
      case 'join_party': {
        const p = parties.get(String(m.code || '').toUpperCase());
        if (!p) return send(ws, { t: 'error', msg: 'No party with that code' });
        if (p.started) return send(ws, { t: 'error', msg: 'Match already in progress' });
        if (p.players.size >= 8) return send(ws, { t: 'error', msg: 'Party is full (8 max)' });
        p.players.set(ws.id, { ws, name: cleanName(m.name), look: cleanLook(m.look), team: autoTeam(p) });
        ws.partyCode = p.code;
        send(ws, { t: 'joined', selfId: ws.id, party: lobbyPayload(p) });
        pushLobby(p);
        break;
      }
      case 'set_look': {
        if (!party) return;
        const me = party.players.get(ws.id);
        if (me) { me.look = cleanLook(m.look); pushLobby(party); }
        break;
      }

      /* ----- custom match hosting (host only) ----- */
      case 'set_mode': {
        if (!party || party.hostId !== ws.id) return;
        if (!['solos', '2v2', '4v4'].includes(m.mode)) return;
        party.mode = m.mode;
        // re-seed teams to match the new mode
        let i = 0;
        for (const [, p] of party.players)
          p.team = party.mode === 'solos' ? 'S' : (i++ % 2 === 0 ? 'A' : 'B');
        pushLobby(party);
        break;
      }
      case 'assign_team': {
        if (!party || party.hostId !== ws.id || party.mode === 'solos') return;
        const target = party.players.get(m.playerId);
        if (target && ['A', 'B'].includes(m.team)) { target.team = m.team; pushLobby(party); }
        break;
      }
      case 'start_match': {
        if (!party || party.hostId !== ws.id || party.started) return;
        party.started = true;
        // Shared seed drives identical map/chest/storm generation on
        // every client — no map data needs to cross the wire.
        broadcast(party, {
          t: 'match_start',
          seed: (Math.random() * 1e9) | 0,
          mode: party.mode,
          hostId: party.hostId, // the host's client simulates guardians (NPCs)
          players: lobbyPayload(party).players,
        });
        break;
      }

      /* ----- in-match relay ----- */
      case 'state':      // my position/hp/aim -> everyone else
        if (party) broadcast(party, { t: 'peer_state', id: ws.id, x: m.x, y: m.y, aim: m.aim, hp: m.hp, alive: m.alive, weapon: m.weapon }, ws.id);
        break;
      case 'shoot':      // replayed visually + simulated on peers
        if (party) broadcast(party, { t: 'peer_shoot', by: ws.id, x: m.x, y: m.y, aim: m.aim, weapon: m.weapon }, ws.id);
        break;
      case 'build':      // placed a piece
        if (party) broadcast(party, { t: 'peer_build', by: ws.id, gx: m.gx, gy: m.gy, piece: m.piece, mat: m.mat }, ws.id);
        break;
      case 'build_hit':  // my bullet damaged a piece
        if (party) broadcast(party, { t: 'build_hit', gx: m.gx, gy: m.gy, dmg: m.dmg }, ws.id);
        break;
      case 'chest_open':
        if (party) broadcast(party, { t: 'chest_open', id: m.id, by: ws.id }, ws.id);
        break;
      case 'pickup_taken': // a special weapon drop was claimed
        if (party) broadcast(party, { t: 'pickup_taken', id: m.id }, ws.id);
        break;
      case 'npc_state':    // host's guardian snapshot -> everyone else
        if (party && party.hostId === ws.id) broadcast(party, { t: 'npc_state', list: m.list }, ws.id);
        break;
      case 'npc_shoot':    // host's guardian fired -> everyone else
        if (party && party.hostId === ws.id) broadcast(party, { t: 'npc_shoot', id: m.id, x: m.x, y: m.y, aim: m.aim }, ws.id);
        break;
      case 'npc_damage': { // someone hit a guardian -> route to the host (NPC authority)
        if (!party) return;
        const host = party.players.get(party.hostId);
        if (host && party.hostId !== ws.id)
          send(host.ws, { t: 'npc_damage', target: m.target, dmg: Math.min(100, Math.max(0, m.dmg | 0)), by: ws.id });
        break;
      }
      case 'damage': {   // route damage to the victim only; their client applies it
        if (!party) return;
        const victim = party.players.get(m.target);
        if (victim) send(victim.ws, { t: 'damage', dmg: Math.min(100, Math.max(0, m.dmg | 0)), by: ws.id });
        break;
      }
    }
  });

  ws.on('close', () => leaveParty(ws));
  ws.on('error', () => leaveParty(ws));
});

function leaveParty(ws) {
  const party = ws.partyCode ? parties.get(ws.partyCode) : null;
  if (!party) return;
  party.players.delete(ws.id);
  ws.partyCode = null;
  if (party.players.size === 0) { parties.delete(party.code); return; }
  // host migration: oldest remaining member becomes host
  if (party.hostId === ws.id) party.hostId = party.players.keys().next().value;
  broadcast(party, { t: 'peer_left', id: ws.id });
  if (!party.started) pushLobby(party);
}

/* ---------- input sanitizers ---------- */
function cleanName(n) { return String(n || 'Player').replace(/[^\w \-!?.]/g, '').slice(0, 12) || 'Player'; }
function cleanLook(l) {
  l = l || {};
  return { eye: clampInt(l.eye, 0, 2), hair: clampInt(l.hair, 0, 2), outfit: clampInt(l.outfit, 0, 3) };
}
function clampInt(v, a, b) { v = v | 0; return v < a ? a : v > b ? b : v; }

httpServer.listen(PORT, () => {
  console.log(`Sleepy Royale server on http://localhost:${PORT}`);
  console.log('Open that URL on each iPad (same network) to play together.');
});
