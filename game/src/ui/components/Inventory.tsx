import { useMemo, useState } from 'react';
import type { EquipSlot, ItemInstance, Rarity, Stats } from '@/shared/types';
import { getItemDef } from '@/content';
import { itemStats } from '@/sim/formulas';
import { useGame } from '../store/gameStore';
import { panelShell, RARITY_COLOR, statLabel, formatStat } from './shared';

const SLOTS: EquipSlot[] = ['weapon', 'head', 'chest', 'hands', 'legs', 'accessory'];

export function Inventory() {
  const character = useGame((s) => s.character);
  const equip = useGame((s) => s.equip);
  const unequip = useGame((s) => s.unequip);
  const sellItem = useGame((s) => s.sellItem);
  const setPanel = useGame((s) => s.setPanel);
  const [hovered, setHovered] = useState<ItemInstance | null>(null);

  const equipped = useMemo(() => {
    const m = new Map<EquipSlot, ItemInstance>();
    for (const i of character.inventory) if (i.equippedSlot) m.set(i.equippedSlot, i);
    return m;
  }, [character.inventory]);

  const bag = useMemo(
    () =>
      character.inventory
        .filter((i) => !i.equippedSlot)
        .sort((a, b) => {
          const ra = RARITY_ORDER[b.rarity] - RARITY_ORDER[a.rarity];
          if (ra !== 0) return ra;
          return (getItemDef(b.defId)?.itemLevel ?? 0) - (getItemDef(a.defId)?.itemLevel ?? 0);
        }),
    [character.inventory],
  );

  return (
    <div style={panelShell(920)}>
      <header style={headerRow}>
        <h2 style={{ margin: 0, fontSize: 19, letterSpacing: 1.5 }}>INVENTORY</h2>
        <button style={closeBtn} onClick={() => setPanel('none')}>
          ✕
        </button>
      </header>

      <div style={{ display: 'grid', gridTemplateColumns: '250px 1fr 240px', gap: 18 }}>
        {/* equipped */}
        <div>
          <h3 style={sectionTitle}>Equipped</h3>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            {SLOTS.map((slot) => {
              const inst = equipped.get(slot);
              const def = inst && getItemDef(inst.defId);
              return (
                <div
                  key={slot}
                  onMouseEnter={() => inst && setHovered(inst)}
                  onMouseLeave={() => setHovered(null)}
                  onClick={() => inst && unequip(slot)}
                  style={{
                    ...slotRow,
                    borderColor: inst ? RARITY_COLOR[inst.rarity] : 'rgba(255,255,255,.1)',
                    cursor: inst ? 'pointer' : 'default',
                  }}
                >
                  <span style={{ fontSize: 10, opacity: 0.5, textTransform: 'uppercase' }}>
                    {slot}
                  </span>
                  <span style={{ color: inst ? RARITY_COLOR[inst.rarity] : 'rgba(255,255,255,.25)' }}>
                    {def ? def.name : '—'}
                  </span>
                </div>
              );
            })}
          </div>
        </div>

        {/* bag */}
        <div>
          <h3 style={sectionTitle}>
            Bag <span style={{ opacity: 0.5, fontWeight: 400 }}>({bag.length})</span>
          </h3>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(auto-fill, minmax(58px, 1fr))',
              gap: 6,
              maxHeight: 340,
              overflowY: 'auto',
              paddingRight: 4,
            }}
          >
            {bag.map((inst) => {
              const def = getItemDef(inst.defId);
              if (!def) return null;
              return (
                <div
                  key={inst.uid}
                  onMouseEnter={() => setHovered(inst)}
                  onMouseLeave={() => setHovered(null)}
                  onClick={() => def.kind === 'equipment' && equip(inst.uid)}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    if (def.kind !== 'key') sellItem(inst.uid);
                  }}
                  title={def.name}
                  style={{
                    aspectRatio: '1',
                    borderRadius: 6,
                    border: `2px solid ${RARITY_COLOR[inst.rarity]}`,
                    background: 'rgba(255,255,255,.04)',
                    display: 'grid',
                    placeItems: 'center',
                    position: 'relative',
                    cursor: def.kind === 'equipment' ? 'pointer' : 'default',
                    fontSize: 10,
                    textAlign: 'center',
                    padding: 3,
                    lineHeight: 1.15,
                    overflow: 'hidden',
                  }}
                >
                  {def.name.split(' ').slice(-1)[0]}
                  {inst.quantity > 1 && (
                    <span
                      style={{
                        position: 'absolute',
                        bottom: 1,
                        right: 3,
                        fontSize: 10,
                        fontWeight: 700,
                      }}
                    >
                      {inst.quantity}
                    </span>
                  )}
                </div>
              );
            })}
            {bag.length === 0 && (
              <div style={{ opacity: 0.4, fontSize: 13, gridColumn: '1 / -1' }}>
                Empty. Go hit something.
              </div>
            )}
          </div>
          <p style={{ fontSize: 11, opacity: 0.45, marginTop: 10 }}>
            Left click to equip · Right click to sell · Hover to compare
          </p>
        </div>

        {/* comparison tooltip */}
        <div>
          <h3 style={sectionTitle}>Details</h3>
          {hovered ? (
            <ItemTooltip inst={hovered} equipped={equipped} />
          ) : (
            <div style={{ opacity: 0.35, fontSize: 12 }}>Hover an item.</div>
          )}
        </div>
      </div>
    </div>
  );
}

/**
 * The comparison delta is the single most valuable feature in an ARPG
 * inventory — without it every drop is a spreadsheet exercise.
 */
function ItemTooltip({
  inst,
  equipped,
}: {
  inst: ItemInstance;
  equipped: Map<EquipSlot, ItemInstance>;
}) {
  const def = getItemDef(inst.defId);
  if (!def) return null;

  const mine = itemStats(inst, def);
  const currentInst = def.slot ? equipped.get(def.slot) : undefined;
  const currentDef = currentInst && getItemDef(currentInst.defId);
  const current = currentInst && currentDef ? itemStats(currentInst, currentDef) : null;
  const isComparing = !!current && currentInst?.uid !== inst.uid;

  const keys: (keyof Stats)[] = [
    'atk',
    'def',
    'maxHp',
    'critChance',
    'critMultiplier',
    'maxStamina',
    'staminaRegen',
  ];

  return (
    <div style={{ fontSize: 12, lineHeight: 1.7 }}>
      <div style={{ color: RARITY_COLOR[inst.rarity], fontWeight: 700, fontSize: 14 }}>
        {def.name}
      </div>
      <div style={{ opacity: 0.5, textTransform: 'capitalize', fontSize: 11 }}>
        {inst.rarity} {def.slot ?? def.kind} · ilvl {def.itemLevel}
      </div>

      <div style={{ marginTop: 8 }}>
        {keys.map((k) => {
          const v = mine[k];
          if (!v) return null;
          const delta = isComparing ? v - (current![k] ?? 0) : 0;
          return (
            <div key={k} style={{ display: 'flex', justifyContent: 'space-between' }}>
              <span style={{ opacity: 0.7 }}>{statLabel(k)}</span>
              <span>
                {formatStat(k, v)}
                {isComparing && Math.abs(delta) > 0.0001 && (
                  <span
                    style={{ color: delta > 0 ? '#7ef0b0' : '#ff8080', marginLeft: 6 }}
                  >
                    {delta > 0 ? '▲' : '▼'} {formatStat(k, Math.abs(delta))}
                  </span>
                )}
              </span>
            </div>
          );
        })}
      </div>

      {inst.affixes.length > 0 && (
        <div style={{ marginTop: 8, borderTop: '1px solid rgba(255,255,255,.1)', paddingTop: 6 }}>
          {inst.affixes.map((a) => (
            <div key={a.id} style={{ color: '#9fd8ff' }}>
              {a.label} +{formatStat(a.stat, a.value)}
            </div>
          ))}
        </div>
      )}

      <p style={{ marginTop: 10, opacity: 0.45, fontStyle: 'italic', fontSize: 11 }}>
        {def.description}
      </p>
      {isComparing && (
        <p style={{ marginTop: 6, opacity: 0.4, fontSize: 10 }}>
          Compared against {currentDef!.name}
        </p>
      )}
    </div>
  );
}

const RARITY_ORDER: Record<Rarity, number> = {
  common: 0,
  uncommon: 1,
  rare: 2,
  epic: 3,
  legendary: 4,
};

const headerRow: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'center',
  marginBottom: 16,
};

const sectionTitle: React.CSSProperties = {
  margin: '0 0 8px',
  fontSize: 11,
  letterSpacing: 2,
  opacity: 0.5,
  textTransform: 'uppercase',
};

const slotRow: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 1,
  padding: '6px 10px',
  borderRadius: 5,
  border: '1px solid',
  background: 'rgba(255,255,255,.03)',
  fontSize: 12,
};

const closeBtn: React.CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: '#e8fff0',
  fontSize: 18,
  cursor: 'pointer',
  opacity: 0.6,
};
