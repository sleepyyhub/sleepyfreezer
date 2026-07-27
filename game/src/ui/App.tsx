import { useEffect, useRef, useState } from 'react';
import { Game } from '@/core/Game';
import { useGame, saveAdapter, scheduler } from './store/gameStore';
import { Hud } from './components/Hud';
import { Inventory } from './components/Inventory';
import { CharacterSheet } from './components/CharacterSheet';
import { panelShell } from './components/shared';

export function App() {
  const gameRef = useRef<Game | null>(null);
  const [booted, setBooted] = useState(false);
  const started = useGame((s) => s.started);
  const panel = useGame((s) => s.panel);
  const dead = useGame((s) => s.dead);

  // Load the save before the Game reads character state to build the world.
  useEffect(() => {
    let cancelled = false;
    void saveAdapter.load().then((saved) => {
      if (cancelled) return;
      if (saved) useGame.getState().loadFrom(saved);
      setBooted(true);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!booted || !started || gameRef.current) return;
    const canvas = document.getElementById('game-canvas') as HTMLCanvasElement;
    const uiRoot = document.getElementById('ui-root') as HTMLElement;
    const game = new Game(canvas, uiRoot);
    gameRef.current = game;
    game.start();
    game.requestPointerLock();

    return () => {
      scheduler.flush();
      game.dispose();
      gameRef.current = null;
    };
  }, [booted, started]);

  // Panel hotkeys live here rather than in Input: they must work while the
  // gameplay input layer is disabled.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const s = useGame.getState();
      if (s.dead) return;
      if (e.code === 'KeyI') s.togglePanel('inventory');
      else if (e.code === 'KeyC') s.togglePanel('character');
      else if (e.code === 'KeyH') s.togglePanel('help');
      else if (e.code === 'Escape') s.setPanel('none');
      else return;
      e.preventDefault();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  // Clicking the canvas after closing a panel re-acquires pointer lock.
  useEffect(() => {
    const onClick = () => {
      if (useGame.getState().panel === 'none' && !useGame.getState().dead) {
        gameRef.current?.requestPointerLock();
      }
    };
    const canvas = document.getElementById('game-canvas');
    canvas?.addEventListener('click', onClick);
    return () => canvas?.removeEventListener('click', onClick);
  }, []);

  if (!booted) return null;
  if (!started) return <TitleScreen />;

  return (
    <>
      <Hud />
      {panel === 'inventory' && <Inventory />}
      {panel === 'character' && <CharacterSheet />}
      {panel === 'help' && <HelpPanel />}
      {dead && <DeathScreen onRespawn={() => gameRef.current?.respawn()} />}
      <BottomHint />
    </>
  );
}

function TitleScreen() {
  const start = useGame((s) => s.start);
  const character = useGame((s) => s.character);
  const resetSave = useGame((s) => s.resetSave);
  const hasSave = character.level > 1 || character.inventory.length > 0;

  return (
    <div
      style={{
        pointerEvents: 'auto',
        position: 'absolute',
        inset: 0,
        display: 'grid',
        placeItems: 'center',
        background: 'radial-gradient(ellipse at 50% 40%, #16352a 0%, #060f0c 70%)',
        textAlign: 'center',
      }}
    >
      <div>
        <h1
          style={{
            fontSize: 'clamp(38px, 7vw, 68px)',
            margin: 0,
            letterSpacing: 8,
            fontWeight: 800,
            background: 'linear-gradient(180deg,#d8ffe4,#4e8f63)',
            WebkitBackgroundClip: 'text',
            WebkitTextFillColor: 'transparent',
          }}
        >
          VERDANT REACH
        </h1>
        <p style={{ opacity: 0.55, letterSpacing: 3, fontSize: 12, marginTop: 4 }}>
          WORLD 1 · LANDING FLATS · VERTICAL SLICE
        </p>

        <button onClick={start} style={primaryBtn}>
          {hasSave ? `Continue — Level ${character.level}` : 'Begin'}
        </button>

        {hasSave && (
          <div>
            <button
              onClick={() => {
                if (confirm('Delete your save and start over?')) resetSave();
              }}
              style={{ ...primaryBtn, ...ghostBtn }}
            >
              New game
            </button>
          </div>
        )}

        <div style={{ marginTop: 34, fontSize: 12, opacity: 0.45, lineHeight: 2 }}>
          <div>WASD move · Mouse look · Click light attack · Right-click / F heavy</div>
          <div>Space dodge (i-frames) · Q surge · E interact · T lock on</div>
          <div>I inventory · C character · H help</div>
        </div>
      </div>
    </div>
  );
}

function DeathScreen({ onRespawn }: { onRespawn: () => void }) {
  return (
    <div
      style={{
        pointerEvents: 'auto',
        position: 'absolute',
        inset: 0,
        display: 'grid',
        placeItems: 'center',
        background: 'rgba(20,4,4,.72)',
        backdropFilter: 'blur(3px)',
      }}
    >
      <div style={{ textAlign: 'center' }}>
        <h2 style={{ fontSize: 44, letterSpacing: 10, margin: 0, color: '#ff8080' }}>
          DEFEATED
        </h2>
        <p style={{ opacity: 0.6, fontSize: 13, marginTop: 8 }}>
          You keep your XP and loot. Enemies reset.
        </p>
        <button onClick={onRespawn} style={primaryBtn}>
          Return to the Flats
        </button>
      </div>
    </div>
  );
}

function HelpPanel() {
  const setPanel = useGame((s) => s.setPanel);
  return (
    <div style={panelShell(560)}>
      <h2 style={{ marginTop: 0, fontSize: 18, letterSpacing: 1.5 }}>HOW TO PLAY</h2>
      <Section title="Combat">
        <li>Light attacks chain three times. The third knocks back.</li>
        <li>
          Heavy attacks deal 2.2x damage and build <strong>stagger</strong> fast.
          Staggered enemies take 50% more damage — light spam will never break a
          Rockhide.
        </li>
        <li>
          Dodge has i-frames from 0.10s to 0.42s of the roll. Inputs buffer 0.2s, so
          pressing early during a swing still works.
        </li>
        <li>Surge (Q) is a cooldown, not a stamina cost. Use it on cooldown.</li>
      </Section>
      <Section title="Telegraphs">
        <li>
          <span style={{ color: '#ff3b3b' }}>Red</span> ground rings mean dodge.{' '}
          <span style={{ color: '#ffcc33' }}>Yellow</span> means a lighter hit you can
          eat.
        </li>
        <li>The decal grows to the real hitbox size — full size means it lands now.</li>
      </Section>
      <Section title="Progression">
        <li>Kill XP falls off against enemies more than 5 levels below you.</li>
        <li>Every level grants 3 stat points. Respec is free.</li>
        <li>Walk south to find the boss. It will not come to you.</li>
      </Section>
      <button onClick={() => setPanel('none')} style={{ ...primaryBtn, marginTop: 18 }}>
        Close
      </button>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <h3
        style={{
          fontSize: 11,
          letterSpacing: 2,
          opacity: 0.5,
          textTransform: 'uppercase',
          margin: '0 0 6px',
        }}
      >
        {title}
      </h3>
      <ul style={{ margin: 0, paddingLeft: 18, fontSize: 12.5, lineHeight: 1.8, opacity: 0.85 }}>
        {children}
      </ul>
    </div>
  );
}

function BottomHint() {
  const panel = useGame((s) => s.panel);
  if (panel !== 'none') return null;
  return (
    <div
      style={{
        position: 'absolute',
        bottom: 14,
        left: 18,
        fontSize: 11,
        opacity: 0.35,
        letterSpacing: 0.5,
      }}
    >
      I inventory · C character · H help · T lock on
    </div>
  );
}

const primaryBtn: React.CSSProperties = {
  pointerEvents: 'auto',
  marginTop: 26,
  padding: '11px 34px',
  fontSize: 14,
  letterSpacing: 2,
  borderRadius: 7,
  border: '1px solid rgba(143,240,208,.45)',
  background: 'rgba(143,240,208,.14)',
  color: '#d8ffe4',
  cursor: 'pointer',
  fontWeight: 600,
};

const ghostBtn: React.CSSProperties = {
  marginTop: 10,
  padding: '7px 22px',
  fontSize: 12,
  border: '1px solid rgba(255,255,255,.14)',
  background: 'transparent',
  color: 'rgba(232,255,240,.55)',
};
