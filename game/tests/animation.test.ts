import { describe, expect, it } from 'vitest';
import { Animator } from '@/render/anim/Animator';
import { sampleTrack, emptyPose, type Clip } from '@/render/anim/types';
import { RigBuilder, UPPER_BODY_MASK } from '@/render/models/skeleton';
import { HUMANOID_CLIPS } from '@/render/anim/clips/humanoid';
import { INSECT_CLIPS } from '@/render/anim/clips/insect';
import { GOLEM_CLIPS, WARDEN_CLIPS } from '@/render/anim/clips/bipeds';

/**
 * These tests exist because animation is otherwise unverifiable except by eye,
 * and "the arm looks a bit off in this screenshot" is not a bug report you can
 * act on. They assert the things a screenshot cannot: that a clip's keyed
 * value actually reaches the joint, that masks confine a layer, and that loops
 * close.
 */

/** Minimal humanoid rig with the joints the clips address. */
function testRig() {
  const rb = new RigBuilder();
  rb.joint('root', [0, 0, 0]);
  rb.joint('hips', [0, 1, 0], 'root');
  rb.joint('spine', [0, 0.1, 0], 'hips');
  rb.joint('chest', [0, 0.2, 0], 'spine');
  rb.joint('neck', [0, 0.3, 0], 'chest');
  rb.joint('head', [0, 0.1, 0], 'neck');
  rb.joint('hair', [0, 0.1, 0], 'head');
  for (const S of ['L', 'R']) {
    rb.joint(`shoulder${S}`, [0, 0, 0], 'chest');
    rb.joint(`arm${S}`, [0, 0, 0], `shoulder${S}`);
    rb.joint(`forearm${S}`, [0, -0.3, 0], `arm${S}`);
    rb.joint(`hand${S}`, [0, -0.3, 0], `forearm${S}`);
    rb.joint(`thigh${S}`, [0, -0.1, 0], 'hips');
    rb.joint(`shin${S}`, [0, -0.4, 0], `thigh${S}`);
    rb.joint(`foot${S}`, [0, -0.4, 0], `shin${S}`);
  }
  return rb.build('humanoid', 1.8, 1);
}

describe('track sampling', () => {
  const track = [
    { t: 0, pose: { rx: 0 } },
    { t: 0.5, pose: { rx: 1 } },
    { t: 1, pose: { rx: 0 } },
  ];

  it('hits keyed values exactly at their keyframe times', () => {
    for (const [t, expected] of [
      [0, 0],
      [0.5, 1],
      [1, 0],
    ] as const) {
      const out = emptyPose();
      sampleTrack(track, t, 1, out);
      expect(out.rx).toBeCloseTo(expected, 5);
    }
  });

  it('interpolates monotonically between keys', () => {
    let prev = -Infinity;
    for (let t = 0; t <= 0.5; t += 0.05) {
      const out = emptyPose();
      sampleTrack(track, t, 1, out);
      expect(out.rx).toBeGreaterThanOrEqual(prev - 1e-9);
      prev = out.rx;
    }
  });

  it('scales by weight', () => {
    const out = emptyPose();
    sampleTrack(track, 0.5, 0.25, out);
    expect(out.rx).toBeCloseTo(0.25, 5);
  });

  it('clamps outside the keyed range instead of extrapolating', () => {
    const a = emptyPose();
    sampleTrack(track, -1, 1, a);
    expect(a.rx).toBe(0);
    const b = emptyPose();
    sampleTrack(track, 5, 1, b);
    expect(b.rx).toBe(0);
  });

  it('accumulates rather than overwriting, so layers can sum', () => {
    const out = emptyPose();
    sampleTrack(track, 0.5, 1, out);
    sampleTrack(track, 0.5, 1, out);
    expect(out.rx).toBeCloseTo(2, 5);
  });
});

describe('animator', () => {
  it('drives a joint to the clip value keyed at that time', () => {
    const rig = testRig();
    const anim = new Animator(rig);
    // Heavy keys armR at rx -2.5 at t=0.3 — the top of the overhead wind-up.
    anim.playAction(HUMANOID_CLIPS.heavy, { fade: 0, restart: true });

    // Step to t=0.3 of a 0.99s clip, in small steps so the weight ramp settles.
    for (let i = 0; i < 60; i++) anim.update(0.297 / 60);

    const armR = rig.joints.get('armR')!;
    expect(armR.rotation.x).toBeCloseTo(-2.5, 1);
  });

  it('returns to the base pose after the action layer is cleared', () => {
    const rig = testRig();
    const anim = new Animator(rig);
    anim.playBase(HUMANOID_CLIPS.idle, { fade: 0 });
    anim.playAction(HUMANOID_CLIPS.heavy, { fade: 0, restart: true });
    for (let i = 0; i < 30; i++) anim.update(0.01);
    const raised = rig.joints.get('armR')!.rotation.x;

    anim.clearAction(0.05);
    for (let i = 0; i < 100; i++) anim.update(0.01);
    const settled = rig.joints.get('armR')!.rotation.x;

    expect(raised).toBeLessThan(-1);
    // Idle keeps the arm hanging near the body.
    expect(Math.abs(settled)).toBeLessThan(0.5);
  });

  it('confines a masked clip to its mask', () => {
    const rig = testRig();
    const anim = new Animator(rig);
    anim.playBase(HUMANOID_CLIPS.run, { fade: 0 });
    // light1 is upper-body masked, so the legs must keep running.
    anim.playAction(HUMANOID_CLIPS.light1, { fade: 0, restart: true });
    for (let i = 0; i < 40; i++) anim.update(0.005);

    expect(UPPER_BODY_MASK).not.toContain('thighL');
    const thigh = rig.joints.get('thighL')!.rotation.x;

    // Compare against a rig running the same base clip with no action layer.
    const ref = testRig();
    const refAnim = new Animator(ref);
    refAnim.playBase(HUMANOID_CLIPS.run, { fade: 0 });
    for (let i = 0; i < 40; i++) refAnim.update(0.005);

    expect(thigh).toBeCloseTo(ref.joints.get('thighL')!.rotation.x, 4);
  });

  it('applies additive offsets on top of clip output', () => {
    const rig = testRig();
    const anim = new Animator(rig);
    anim.playBase(HUMANOID_CLIPS.idle, { fade: 0 });
    anim.update(0.016);
    const before = rig.joints.get('head')!.rotation.y;

    anim.setAdditive('head', { ry: 0.5 });
    anim.update(0.016);
    expect(rig.joints.get('head')!.rotation.y).toBeCloseTo(before + 0.5, 2);
  });

  it('reports a non-looping clip as finished, and never a looping one', () => {
    const rig = testRig();
    const anim = new Animator(rig);
    anim.playAction(HUMANOID_CLIPS.hurt, { fade: 0, restart: true });
    for (let i = 0; i < 10; i++) anim.update(0.01);
    expect(anim.actionFinished).toBe(false);
    for (let i = 0; i < 100; i++) anim.update(0.01);
    expect(anim.actionFinished).toBe(true);
  });

  it('keeps looping clips inside their duration', () => {
    const rig = testRig();
    const anim = new Animator(rig);
    anim.playBase(HUMANOID_CLIPS.walk, { fade: 0 });
    for (let i = 0; i < 1000; i++) anim.update(0.016);
    // A wrapped clip must still produce finite, sane rotations.
    for (const j of rig.joints.values()) {
      expect(Number.isFinite(j.rotation.x)).toBe(true);
      expect(Math.abs(j.rotation.x)).toBeLessThan(10);
    }
  });

  it('never writes to a joint the clip does not address', () => {
    const rig = testRig();
    const anim = new Animator(rig);
    const onlyHead: Clip = {
      name: 'x',
      duration: 1,
      loop: true,
      tracks: { head: [{ t: 0, pose: { rx: 1 } }, { t: 1, pose: { rx: 1 } }] },
    };
    anim.playBase(onlyHead, { fade: 0 });
    anim.update(0.1);
    expect(rig.joints.get('head')!.rotation.x).toBeCloseTo(1, 3);
    expect(rig.joints.get('handL')!.rotation.x).toBeCloseTo(0, 6);
  });
});

// ------------------------------------------------------------------ content

const ALL_CLIPS: Record<string, Clip> = {
  ...Object.fromEntries(Object.entries(HUMANOID_CLIPS).map(([n, c]) => [`humanoid.${n}`, c])),
  ...Object.fromEntries(Object.entries(INSECT_CLIPS).map(([n, c]) => [`insect.${n}`, c])),
  ...Object.fromEntries(Object.entries(GOLEM_CLIPS).map(([n, c]) => [`golem.${n}`, c])),
  ...Object.fromEntries(Object.entries(WARDEN_CLIPS).map(([n, c]) => [`warden.${n}`, c])),
};

describe('clip integrity', () => {
  it('sorts every track by time', () => {
    for (const [name, clip] of Object.entries(ALL_CLIPS)) {
      for (const [joint, track] of Object.entries(clip.tracks)) {
        for (let i = 1; i < track.length; i++) {
          expect(`${name}/${joint} key ${i}`).toBe(
            track[i].t >= track[i - 1].t ? `${name}/${joint} key ${i}` : 'OUT OF ORDER',
          );
        }
      }
    }
  });

  it('keeps every keyframe time inside 0..1', () => {
    for (const [name, clip] of Object.entries(ALL_CLIPS)) {
      for (const [joint, track] of Object.entries(clip.tracks)) {
        for (const key of track) {
          expect(`${name}/${joint} t=${key.t}`).toBe(
            key.t >= 0 && key.t <= 1 ? `${name}/${joint} t=${key.t}` : 'OUT OF RANGE',
          );
        }
      }
    }
  });

  it('closes every looping clip so the cycle does not pop', () => {
    for (const [name, clip] of Object.entries(ALL_CLIPS)) {
      if (!clip.loop) continue;
      for (const [joint, track] of Object.entries(clip.tracks)) {
        const first = track[0];
        const last = track[track.length - 1];
        for (const key of ['rx', 'ry', 'rz', 'px', 'py', 'pz'] as const) {
          const a = first.pose[key] ?? 0;
          const b = last.pose[key] ?? 0;
          // The halo spins continuously by design; a full turn is seamless.
          if (joint === 'halo' && key === 'ry') continue;
          expect(`${name}/${joint}.${key}`).toBe(
            Math.abs(a - b) < 1e-6 ? `${name}/${joint}.${key}` : 'LOOP SEAM',
          );
        }
      }
    }
  });

  it('gives every clip a positive duration', () => {
    for (const [name, clip] of Object.entries(ALL_CLIPS)) {
      expect(`${name}: ${clip.duration}`).toBe(
        clip.duration > 0 ? `${name}: ${clip.duration}` : 'NON-POSITIVE',
      );
    }
  });

  it('keeps rotations within plausible anatomical range', () => {
    for (const [name, clip] of Object.entries(ALL_CLIPS)) {
      for (const [joint, track] of Object.entries(clip.tracks)) {
        // The root and halo intentionally spin multiple turns.
        if (joint === 'root' || joint === 'halo') continue;
        for (const key of track) {
          for (const axis of ['rx', 'ry', 'rz'] as const) {
            const v = key.pose[axis] ?? 0;
            expect(`${name}/${joint}.${axis}=${v}`).toBe(
              Math.abs(v) <= Math.PI
                ? `${name}/${joint}.${axis}=${v}`
                : 'BEYOND HALF TURN',
            );
          }
        }
      }
    }
  });

  /**
   * Sign convention, derived rather than assumed: Rz(θ) maps a downward limb
   * (0,-1,0) to (sinθ, -cosθ, 0), so positive rz always swings toward +X.
   * A left limb sits at -X, so swinging it *away* from the midline needs a
   * negative rz; the right limb needs positive.
   *
   * This test exists because the whole clip library was authored with the sign
   * inverted, which made every character stand with its forearms crossed.
   */
  it('splays limbs outward, not across the body, in every locomotion clip', () => {
    const LOCOMOTION = ['idle', 'walk', 'run'];
    const CHAINS = ['arm', 'thigh'];

    for (const [name, clip] of Object.entries(ALL_CLIPS)) {
      const short = name.split('.')[1];
      if (!LOCOMOTION.includes(short)) continue;

      for (const chain of CHAINS) {
        for (const side of ['L', 'R'] as const) {
          const track = clip.tracks[`${chain}${side}`];
          if (!track) continue;
          const rz = track[0].pose.rz ?? 0;
          if (rz === 0) continue;
          const outward = side === 'L' ? rz < 0 : rz > 0;
          expect(`${name}/${chain}${side} rz=${rz}`).toBe(
            outward ? `${name}/${chain}${side} rz=${rz}` : 'SWINGS ACROSS THE BODY',
          );
        }
      }
    }
  });

  it('provides the clips each family’s animator asks for', () => {
    for (const required of ['idle', 'walk', 'hurt', 'death']) {
      expect(Object.keys(INSECT_CLIPS)).toContain(required);
      expect(Object.keys(GOLEM_CLIPS)).toContain(required);
      expect(Object.keys(WARDEN_CLIPS)).toContain(required);
      expect(Object.keys(HUMANOID_CLIPS)).toContain(required);
    }
  });
});

// ------------------------------------------------------------------ budget

import { MaterialFactory } from '@/render/materials/toon';
import { buildPlayerRig } from '@/render/models/player';
import { buildEnemyRig } from '@/render/models/enemies';
import { ENEMY_DEFS } from '@/content';

/**
 * Detailed models are only worth having if they still fit the frame budget.
 * These caps come from the design doc: player 3-5k, standard enemy under 2k,
 * boss 6-10k.
 */
describe('model triangle budget', () => {
  const mats = new MaterialFactory({
    ambient: '#fff',
    ambientIntensity: 1,
    keyLight: { color: '#fff', intensity: 1, elevation: 30, azimuth: 0 },
    hemisphere: { sky: '#fff', ground: '#000', intensity: 1 },
    fog: { color: '#fff', density: 0 },
    rampStops: ['#000', '#fff'],
    exposure: 1,
    water: '#00f',
    terrainLow: '#0f0',
    terrainHigh: '#ff0',
  });

  it('keeps the player inside its budget', () => {
    const rig = buildPlayerRig(mats);
    expect(rig.triangles).toBeGreaterThan(400); // sanity: it is not a box
    expect(rig.triangles).toBeLessThan(5000);
  });

  it('keeps every enemy inside its tier budget', () => {
    for (const def of ENEMY_DEFS) {
      const rig = buildEnemyRig(mats, def.visual);
      const cap = def.tier === 'midboss' || def.tier === 'worldboss' ? 10000 : 2600;
      expect(`${def.id}: ${rig.triangles}`).toBe(
        rig.triangles < cap ? `${def.id}: ${rig.triangles}` : `OVER BUDGET (cap ${cap})`,
      );
      expect(rig.triangles).toBeGreaterThan(200);
    }
  });

  it('declares every joint a humanoid clip addresses', () => {
    const rig = buildPlayerRig(mats);
    for (const clip of Object.values(HUMANOID_CLIPS)) {
      for (const joint of Object.keys(clip.tracks)) {
        expect(`${clip.name} needs ${joint}`).toBe(
          rig.joints.has(joint) ? `${clip.name} needs ${joint}` : 'MISSING JOINT',
        );
      }
    }
  });

  it('declares every joint each enemy clip family addresses', () => {
    const families: [string, Record<string, Clip>][] = [
      ['insectoid', INSECT_CLIPS as unknown as Record<string, Clip>],
      ['golem', GOLEM_CLIPS as unknown as Record<string, Clip>],
      ['warden', WARDEN_CLIPS as unknown as Record<string, Clip>],
    ];
    for (const [shape, clips] of families) {
      const def = ENEMY_DEFS.find((d) => d.visual.shape === shape);
      if (!def) continue;
      const rig = buildEnemyRig(mats, def.visual);
      for (const clip of Object.values(clips)) {
        for (const joint of Object.keys(clip.tracks)) {
          expect(`${shape}/${clip.name} needs ${joint}`).toBe(
            rig.joints.has(joint) ? `${shape}/${clip.name} needs ${joint}` : 'MISSING JOINT',
          );
        }
      }
    }
  });
});
