import type { StatKey, Stats } from '@/shared/types';
import { mitigation, MITIGATION_K, xpToReach, CRIT_CHANCE_CAP } from '@/sim/formulas';
import { useGame } from '../store/gameStore';
import { panelShell, statLabel, formatStat } from './shared';

const STAT_INFO: { key: StatKey; name: string; blurb: string }[] = [
  { key: 'vit', name: 'Vitality', blurb: '+12 max health per point.' },
  { key: 'str', name: 'Strength', blurb: '+1.8 attack per point.' },
  { key: 'end', name: 'Endurance', blurb: '+1.4 defence, +3 stamina, +0.25 regen.' },
  { key: 'agi', name: 'Agility', blurb: '+0.4% crit chance, +0.6% crit damage.' },
];

export function CharacterSheet() {
  const character = useGame((s) => s.character);
  const stats = useGame((s) => s.stats);
  const allocate = useGame((s) => s.allocate);
  const respec = useGame((s) => s.respec);
  const setPanel = useGame((s) => s.setPanel);

  const floor = xpToReach(character.level);
  const ceil = xpToReach(character.level + 1);

  const displayed: (keyof Stats)[] = [
    'maxHp',
    'atk',
    'def',
    'critChance',
    'critMultiplier',
    'maxStamina',
    'staminaRegen',
  ];

  return (
    <div style={panelShell(680)}>
      <header
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          marginBottom: 18,
        }}
      >
        <div>
          <h2 style={{ margin: 0, fontSize: 19, letterSpacing: 1.5 }}>CHARACTER</h2>
          <div style={{ fontSize: 12, opacity: 0.55, marginTop: 3 }}>
            Level {character.level} · {character.xp - floor} / {ceil - floor} XP
          </div>
        </div>
        <button
          style={{
            background: 'transparent',
            border: 'none',
            color: '#e8fff0',
            fontSize: 18,
            cursor: 'pointer',
            opacity: 0.6,
          }}
          onClick={() => setPanel('none')}
        >
          ✕
        </button>
      </header>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 24 }}>
        <div>
          <h3 style={sectionTitle}>Attributes</h3>
          {character.statPoints > 0 && (
            <div style={{ fontSize: 12, color: '#ffe08a', marginBottom: 8 }}>
              {character.statPoints} unspent point{character.statPoints > 1 ? 's' : ''}
            </div>
          )}
          {STAT_INFO.map((s) => (
            <div key={s.key} style={statRow}>
              <div>
                <div style={{ fontSize: 13 }}>{s.name}</div>
                <div style={{ fontSize: 10, opacity: 0.42 }}>{s.blurb}</div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontVariantNumeric: 'tabular-nums', minWidth: 20, textAlign: 'right' }}>
                  {character.allocation[s.key]}
                </span>
                <button
                  disabled={character.statPoints <= 0}
                  onClick={() => allocate(s.key)}
                  style={{
                    ...plusBtn,
                    opacity: character.statPoints > 0 ? 1 : 0.25,
                    cursor: character.statPoints > 0 ? 'pointer' : 'default',
                  }}
                >
                  +
                </button>
              </div>
            </div>
          ))}
          <button onClick={respec} style={respecBtn}>
            Respec (free in prototype)
          </button>
        </div>

        <div>
          <h3 style={sectionTitle}>Derived</h3>
          {displayed.map((k) => (
            <div key={k} style={{ ...statRow, paddingBlock: 5 }}>
              <span style={{ fontSize: 13, opacity: 0.8 }}>{statLabel(k)}</span>
              <span style={{ fontVariantNumeric: 'tabular-nums' }}>
                {formatStat(k, stats[k])}
                {k === 'critChance' && stats.critChance >= CRIT_CHANCE_CAP && (
                  <span style={{ fontSize: 10, opacity: 0.5, marginLeft: 5 }}>(cap)</span>
                )}
              </span>
            </div>
          ))}

          {/* Explaining the DEF curve is what turns gear into a decision
              rather than a bigger-number reflex. */}
          <div
            style={{
              marginTop: 14,
              padding: 10,
              borderRadius: 6,
              background: 'rgba(255,255,255,.04)',
              fontSize: 11,
              lineHeight: 1.6,
              opacity: 0.7,
            }}
          >
            Defence uses <code>{MITIGATION_K}/({MITIGATION_K}+DEF)</code> — it never
            reaches 100% and never produces a zero-damage hit. At {stats.def} DEF you
            take <strong>{(mitigation(stats.def) * 100).toFixed(1)}%</strong> of
            incoming damage.
          </div>
        </div>
      </div>
    </div>
  );
}

const sectionTitle: React.CSSProperties = {
  margin: '0 0 10px',
  fontSize: 11,
  letterSpacing: 2,
  opacity: 0.5,
  textTransform: 'uppercase',
};

const statRow: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'center',
  paddingBlock: 7,
  borderBottom: '1px solid rgba(255,255,255,.06)',
};

const plusBtn: React.CSSProperties = {
  width: 24,
  height: 24,
  borderRadius: 5,
  border: '1px solid rgba(143,240,208,.4)',
  background: 'rgba(143,240,208,.12)',
  color: '#c9ffe6',
  fontSize: 15,
  lineHeight: 1,
};

const respecBtn: React.CSSProperties = {
  marginTop: 14,
  width: '100%',
  padding: '7px 0',
  borderRadius: 6,
  border: '1px solid rgba(255,255,255,.15)',
  background: 'transparent',
  color: 'rgba(232,255,240,.7)',
  fontSize: 12,
  cursor: 'pointer',
};
