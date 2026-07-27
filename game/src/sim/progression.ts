import type { CharacterState, Condition } from '@/shared/types';

/**
 * Every gate in the game — zone exits, world unlocks, vendor stock, quest
 * steps — routes through this one predicate. Adding a gate type is one case
 * arm here plus one entry in the content schema.
 */
export function isSatisfied(c: Condition, s: CharacterState): boolean {
  switch (c.type) {
    case 'default':
      return true;
    case 'level':
      return s.level >= c.min;
    case 'flag':
      return s.flags[c.key] === true;
    case 'keyItem':
      return s.inventory.some((i) => i.defId === c.id);
    case 'killCount':
      return (s.kills[c.zone] ?? 0) >= c.count;
    case 'all':
      return c.conditions.every((x) => isSatisfied(x, s));
    case 'any':
      return c.conditions.some((x) => isSatisfied(x, s));
  }
}

/**
 * Human-readable requirement text. Locked content always shows *why* it is
 * locked — a bare padlock is a wall, a stated requirement is a goal.
 */
export function describeCondition(c: Condition, s: CharacterState): string[] {
  switch (c.type) {
    case 'default':
      return [];
    case 'level':
      return [`Reach level ${c.min} (you are ${s.level})`];
    case 'flag':
      return [`Defeat ${prettyFlag(c.key)}`];
    case 'keyItem':
      return [`Obtain ${prettyId(c.id)}`];
    case 'killCount':
      return [
        `Defeat ${c.count} enemies in ${prettyId(c.zone)} (${s.kills[c.zone] ?? 0}/${c.count})`,
      ];
    case 'all':
      return c.conditions.flatMap((x) => describeCondition(x, s));
    case 'any':
      return [c.conditions.flatMap((x) => describeCondition(x, s)).join(' — or — ')];
  }
}

function prettyFlag(key: string): string {
  return prettyId(key.replace(/^boss\./, '').replace(/\.killed$/, ''));
}

function prettyId(id: string): string {
  return id
    .replace(/^[wz]\d+_/, '')
    .split('_')
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}
