import { describe, expect, it } from 'vitest';
import { isSatisfied, describeCondition } from '@/sim/progression';
import { initialCharacter } from '@/net/save';
import type { CharacterState, Condition } from '@/shared/types';

function character(over: Partial<CharacterState> = {}): CharacterState {
  return { ...initialCharacter(), ...over };
}

describe('gate conditions', () => {
  it('default is always open', () => {
    expect(isSatisfied({ type: 'default' }, character())).toBe(true);
  });

  it('level gates on the floor, inclusive', () => {
    const c: Condition = { type: 'level', min: 15 };
    expect(isSatisfied(c, character({ level: 14 }))).toBe(false);
    expect(isSatisfied(c, character({ level: 15 }))).toBe(true);
    expect(isSatisfied(c, character({ level: 30 }))).toBe(true);
  });

  it('flags require an explicit true, not merely presence', () => {
    const c: Condition = { type: 'flag', key: 'boss.x.killed' };
    expect(isSatisfied(c, character())).toBe(false);
    expect(isSatisfied(c, character({ flags: { 'boss.x.killed': false } }))).toBe(false);
    expect(isSatisfied(c, character({ flags: { 'boss.x.killed': true } }))).toBe(true);
  });

  it('key items check the inventory', () => {
    const c: Condition = { type: 'keyItem', id: 'fractured_dragon_sigil' };
    expect(isSatisfied(c, character())).toBe(false);
    expect(
      isSatisfied(
        c,
        character({
          inventory: [
            {
              uid: 'a',
              defId: 'fractured_dragon_sigil',
              quantity: 1,
              rarity: 'common',
              affixes: [],
              equippedSlot: null,
            },
          ],
        }),
      ),
    ).toBe(true);
  });

  it('kill counts default to zero for unvisited zones', () => {
    const c: Condition = { type: 'killCount', zone: 'z1_landing_flats', count: 12 };
    expect(isSatisfied(c, character())).toBe(false);
    expect(isSatisfied(c, character({ kills: { z1_landing_flats: 12 } }))).toBe(true);
  });
});

describe('composite gates', () => {
  // The real World 1 -> World 2 gate: level AND boss flag AND key item.
  const worldTwoGate: Condition = {
    type: 'all',
    conditions: [
      { type: 'level', min: 15 },
      { type: 'flag', key: 'boss.grand_elder_kaanu.killed' },
      { type: 'keyItem', id: 'fractured_dragon_sigil' },
    ],
  };

  const fullyQualified = character({
    level: 15,
    flags: { 'boss.grand_elder_kaanu.killed': true },
    inventory: [
      {
        uid: 'a',
        defId: 'fractured_dragon_sigil',
        quantity: 1,
        rarity: 'common',
        affixes: [],
        equippedSlot: null,
      },
    ],
  });

  it('opens only when every condition holds', () => {
    expect(isSatisfied(worldTwoGate, fullyQualified)).toBe(true);
  });

  it('stays closed if any single condition fails', () => {
    expect(isSatisfied(worldTwoGate, { ...fullyQualified, level: 14 })).toBe(false);
    expect(isSatisfied(worldTwoGate, { ...fullyQualified, flags: {} })).toBe(false);
    expect(isSatisfied(worldTwoGate, { ...fullyQualified, inventory: [] })).toBe(false);
  });

  it('any-gates open on a single satisfied branch', () => {
    const c: Condition = {
      type: 'any',
      conditions: [
        { type: 'level', min: 12 },
        { type: 'killCount', zone: 'z3', count: 25 },
      ],
    };
    expect(isSatisfied(c, character({ level: 12 }))).toBe(true);
    expect(isSatisfied(c, character({ level: 5, kills: { z3: 25 } }))).toBe(true);
    expect(isSatisfied(c, character({ level: 5 }))).toBe(false);
  });

  it('nests arbitrarily deep', () => {
    const c: Condition = {
      type: 'all',
      conditions: [
        { type: 'level', min: 5 },
        {
          type: 'any',
          conditions: [
            { type: 'flag', key: 'a' },
            { type: 'flag', key: 'b' },
          ],
        },
      ],
    };
    expect(isSatisfied(c, character({ level: 5, flags: { b: true } }))).toBe(true);
    expect(isSatisfied(c, character({ level: 5 }))).toBe(false);
  });
});

describe('gate descriptions', () => {
  it('always states the requirement, never a bare padlock', () => {
    const lines = describeCondition(
      {
        type: 'all',
        conditions: [
          { type: 'level', min: 15 },
          { type: 'keyItem', id: 'fractured_dragon_sigil' },
        ],
      },
      character({ level: 9 }),
    );
    expect(lines).toHaveLength(2);
    expect(lines[0]).toContain('15');
    expect(lines[0]).toContain('9');
    expect(lines[1]).toContain('Fractured Dragon Sigil');
  });
});
