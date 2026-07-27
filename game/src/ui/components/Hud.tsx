import { useEffect, useRef, useState } from 'react';
import { useGame } from '../store/gameStore';
import { xpToReach } from '@/sim/formulas';

export function Hud() {
  const vitals = useGame((s) => s.vitals);
  const character = useGame((s) => s.character);
  const toasts = useGame((s) => s.toasts);

  const hpPct = (vitals.hp / Math.max(1, vitals.maxHp)) * 100;
  const staminaPct = (vitals.stamina / Math.max(1, vitals.maxStamina)) * 100;

  const floor = xpToReach(character.level);
  const ceil = xpToReach(character.level + 1);
  const xpPct = ceil > floor ? ((character.xp - floor) / (ceil - floor)) * 100 : 100;

  const specialReady = vitals.specialCooldown <= 0;
  const specialPct = specialReady
    ? 100
    : (1 - vitals.specialCooldown / vitals.specialCooldownMax) * 100;

  return (
    <>
      {/* health + stamina */}
      <div style={{ position: 'absolute', top: 18, left: 18, width: 300 }}>
        <div style={barShell(20)}>
          <GhostBar pct={hpPct} color="#ff4d4d" />
          <span style={barLabel}>
            {vitals.hp} / {vitals.maxHp}
          </span>
        </div>
        <div style={{ ...barShell(9), marginTop: 5, width: 230 }}>
          <div
            style={{
              ...barFill,
              width: `${staminaPct}%`,
              background: 'linear-gradient(90deg,#4ce0a5,#8ff0d0)',
            }}
          />
        </div>
        <div style={{ marginTop: 7, fontSize: 12, opacity: 0.75, letterSpacing: 0.4 }}>
          Level {character.level} · {character.currencies.zeni ?? 0} zeni
          {character.statPoints > 0 && (
            <span style={{ color: '#ffe08a', marginLeft: 8 }}>
              ● {character.statPoints} points to spend [C]
            </span>
          )}
        </div>
      </div>

      {/* boss bar */}
      {vitals.bossName && (
        <div
          style={{
            position: 'absolute',
            top: 26,
            left: '50%',
            transform: 'translateX(-50%)',
            width: 'min(560px, 60vw)',
            textAlign: 'center',
          }}
        >
          <div
            style={{
              fontSize: 15,
              letterSpacing: 3,
              textTransform: 'uppercase',
              marginBottom: 6,
              textShadow: '0 2px 6px rgba(0,0,0,.8)',
            }}
          >
            {vitals.bossName}
          </div>
          <div style={barShell(13)}>
            <GhostBar
              pct={(vitals.bossHp / Math.max(1, vitals.bossMaxHp)) * 100}
              color="#c94fd9"
            />
          </div>
        </div>
      )}

      {/* xp */}
      <div
        style={{
          position: 'absolute',
          bottom: 18,
          left: '50%',
          transform: 'translateX(-50%)',
          width: 'min(520px, 55vw)',
        }}
      >
        <div style={barShell(7)}>
          <div
            style={{
              ...barFill,
              width: `${xpPct}%`,
              background: 'linear-gradient(90deg,#7bd6ff,#c9a5ff)',
            }}
          />
        </div>
      </div>

      {/* ability */}
      <div style={{ position: 'absolute', bottom: 42, right: 24, display: 'flex', gap: 10 }}>
        <AbilityIcon label="Q" name="Surge" pct={specialPct} ready={specialReady} />
      </div>

      {/* interact prompt */}
      {vitals.interactPrompt && (
        <div
          style={{
            position: 'absolute',
            bottom: '32%',
            left: '50%',
            transform: 'translateX(-50%)',
            padding: '7px 16px',
            borderRadius: 6,
            background: 'rgba(8,18,14,.8)',
            border: '1px solid rgba(143,240,208,.35)',
            fontSize: 14,
          }}
        >
          {vitals.interactPrompt}
        </div>
      )}

      {/* toasts */}
      <div
        style={{
          position: 'absolute',
          right: 24,
          top: 90,
          display: 'flex',
          flexDirection: 'column',
          gap: 6,
          alignItems: 'flex-end',
        }}
      >
        {toasts.map((t) => (
          <div
            key={t.id}
            style={{
              padding: '6px 12px',
              borderRadius: 5,
              fontSize: 13,
              background: 'rgba(8,18,14,.82)',
              borderLeft: `3px solid ${
                t.tone === 'good' ? '#8ff0d0' : t.tone === 'bad' ? '#ff7b7b' : '#9fb8ad'
              }`,
            }}
          >
            {t.text}
          </div>
        ))}
      </div>

      <div
        style={{
          position: 'absolute',
          top: 8,
          right: 12,
          fontSize: 11,
          opacity: 0.45,
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {vitals.fps} fps
      </div>
    </>
  );
}

/**
 * A trailing "ghost" bar that catches up after the real one drops. It is the
 * cheapest way to make a hit read as impact rather than a number changing.
 */
function GhostBar({ pct, color }: { pct: number; color: string }) {
  const [ghost, setGhost] = useState(pct);
  const ghostRef = useRef(pct);

  useEffect(() => {
    // Gains snap; only losses trail, which is what makes damage read.
    if (pct >= ghostRef.current) {
      ghostRef.current = pct;
      setGhost(pct);
      return;
    }
    let raf = 0;
    const tick = () => {
      ghostRef.current += (pct - ghostRef.current) * 0.12;
      if (Math.abs(ghostRef.current - pct) < 0.3) ghostRef.current = pct;
      setGhost(ghostRef.current);
      if (ghostRef.current !== pct) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [pct]);

  return (
    <>
      <div
        style={{
          ...barFill,
          width: `${Math.max(pct, ghost)}%`,
          background: 'rgba(255,255,255,.35)',
          transition: 'none',
        }}
      />
      <div style={{ ...barFill, width: `${pct}%`, background: color }} />
    </>
  );
}

function AbilityIcon({
  label,
  name,
  pct,
  ready,
}: {
  label: string;
  name: string;
  pct: number;
  ready: boolean;
}) {
  return (
    <div style={{ textAlign: 'center' }}>
      <div
        style={{
          width: 54,
          height: 54,
          borderRadius: 10,
          position: 'relative',
          overflow: 'hidden',
          border: `2px solid ${ready ? '#ffe08a' : 'rgba(255,255,255,.2)'}`,
          background: 'rgba(8,18,14,.75)',
          display: 'grid',
          placeItems: 'center',
          fontWeight: 700,
          fontSize: 18,
          color: ready ? '#ffe08a' : 'rgba(255,255,255,.4)',
          boxShadow: ready ? '0 0 14px rgba(255,224,138,.3)' : 'none',
        }}
      >
        {label}
        {!ready && (
          <div
            style={{
              position: 'absolute',
              inset: 0,
              background: 'rgba(0,0,0,.55)',
              clipPath: `inset(${100 - pct}% 0 0 0)`,
            }}
          />
        )}
      </div>
      <div style={{ fontSize: 10, opacity: 0.6, marginTop: 3 }}>{name}</div>
    </div>
  );
}

const barShell = (h: number): React.CSSProperties => ({
  position: 'relative',
  height: h,
  borderRadius: h / 2,
  background: 'rgba(6,14,11,.75)',
  border: '1px solid rgba(255,255,255,.12)',
  overflow: 'hidden',
});

const barFill: React.CSSProperties = {
  position: 'absolute',
  left: 0,
  top: 0,
  bottom: 0,
  borderRadius: 'inherit',
  transition: 'width .12s linear',
};

const barLabel: React.CSSProperties = {
  position: 'absolute',
  inset: 0,
  display: 'grid',
  placeItems: 'center',
  fontSize: 11,
  fontWeight: 700,
  textShadow: '0 1px 3px rgba(0,0,0,.9)',
  fontVariantNumeric: 'tabular-nums',
};
