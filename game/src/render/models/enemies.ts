import * as THREE from 'three';
import type { MaterialFactory } from '../materials/toon';
import { RigBuilder, type Rig } from './skeleton';
import { buildFoot, buildHand, mergeAll, profileMesh, shapedBox, transform } from './geom';

export interface EnemyVisual {
  color: number;
  accent: number;
  scale: number;
  shape: string;
}

export function buildEnemyRig(mats: MaterialFactory, visual: EnemyVisual): Rig {
  switch (visual.shape) {
    case 'insectoid':
      return buildGrasshopper(mats, visual);
    case 'golem':
      return buildGolem(mats, visual);
    default:
      return buildWarden(mats, visual);
  }
}

/** Insect leg joint names, front/middle/back by left/right. */
export const INSECT_LEGS = ['FL', 'FR', 'ML', 'MR', 'BL', 'BR'] as const;
export type InsectLeg = (typeof INSECT_LEGS)[number];

/**
 * Six-legged grasshopper with a real insect leg: coxa, a femur that angles up
 * and out, a tibia angling back down, and a tarsus on the ground. The rear
 * pair is the oversized jumping pair, which is the whole silhouette.
 */
function buildGrasshopper(mats: MaterialFactory, visual: EnemyVisual): Rig {
  const rb = new RigBuilder();
  const body = mats.toon(visual.color);
  const dark = mats.toon(0x5f8f2c);
  const accent = mats.toon(visual.accent, 0.25);
  const eye = mats.toon(0x1a1410);

  rb.joint('root', [0, 0, 0]);
  rb.joint('thorax', [0, 0.44, 0], 'root');
  rb.joint('abdomen', [0, -0.01, -0.2], 'thorax');
  rb.joint('head', [0, 0.02, 0.24], 'thorax');
  rb.joint('mandibleL', [-0.04, -0.06, 0.12], 'head');
  rb.joint('mandibleR', [0.04, -0.06, 0.12], 'head');
  rb.joint('antennaL', [-0.05, 0.09, 0.1], 'head');
  rb.joint('antennaR', [0.05, 0.09, 0.1], 'head');
  rb.joint('wingL', [-0.07, 0.09, -0.06], 'thorax');
  rb.joint('wingR', [0.07, 0.09, -0.06], 'thorax');

  // Segmented thorax — three plates with visible gaps.
  rb.attach('thorax', profileMesh(
    [
      { y: 0.13, rx: 0.13, rz: 0.15 },
      { y: 0.05, rx: 0.17, rz: 0.2 },
      { y: -0.06, rx: 0.155, rz: 0.19 },
      { y: -0.13, rx: 0.1, rz: 0.13 },
    ], 6), body, { rotation: [Math.PI / 2, 0, 0] });
  rb.attach('thorax', shapedBox(0.28, 0.075, 0.17, { topScale: 0.72 }), dark, {
    position: [0, 0.1, 0.03],
    rotation: [-0.18, 0, 0],
  });

  // Abdomen: tapering segments, each ring slightly narrower.
  rb.attach('abdomen', buildSegmentedAbdomen(), body);
  rb.attach('abdomen', profileMesh([{ y: 0, rx: 0.02, rz: 0.02 }, { y: -0.11, rx: 0.005, rz: 0.005 }], 4), dark, {
    position: [0, 0.01, -0.34],
    rotation: [-1.35, 0, 0],
  });

  // Head with compound eyes and mandibles.
  rb.attach('head', profileMesh(
    [
      { y: 0.1, rx: 0.075, rz: 0.075 },
      { y: 0.02, rx: 0.098, rz: 0.1 },
      { y: -0.08, rx: 0.08, rz: 0.09 },
      { y: -0.14, rx: 0.05, rz: 0.06 },
    ], 6), body, { rotation: [Math.PI / 2.2, 0, 0] });
  for (const side of [-1, 1] as const) {
    rb.attach('head', profileMesh(
      [
        { y: 0.035, rx: 0.035, rz: 0.042 },
        { y: 0, rx: 0.046, rz: 0.055 },
        { y: -0.04, rx: 0.03, rz: 0.038 },
      ], 5), eye, { position: [side * 0.072, 0.045, 0.05], rotation: [0.3, 0, side * 0.25] });
  }
  for (const S of ['L', 'R'] as const) {
    const side = S === 'L' ? -1 : 1;
    rb.attach(`mandible${S}`, profileMesh(
      [
        { y: 0, rx: 0.022, rz: 0.02 },
        { y: -0.055, rx: 0.014, rz: 0.013 },
        { y: -0.085, rx: 0.004, rz: 0.004 },
      ], 4), dark, { rotation: [0.5, 0, side * 0.35] });
    rb.attach(`antenna${S}`, buildAntenna(), accent, { rotation: [-0.5, 0, side * 0.45] });
  }

  // Folded wing covers over the abdomen.
  for (const S of ['L', 'R'] as const) {
    const side = S === 'L' ? -1 : 1;
    rb.attach(`wing${S}`, profileMesh(
      [
        { y: 0, rx: 0.055, rz: 0.04 },
        { y: -0.22, rx: 0.05, rz: 0.03 },
        { y: -0.36, rx: 0.02, rz: 0.014 },
      ], 4), dark, { rotation: [-1.42, 0, side * 0.2] });
  }

  // ------------------------------------------------------------- legs
  const legSpec: Record<InsectLeg, { z: number; splay: number; scale: number; jump: boolean }> = {
    FL: { z: 0.14, splay: 0.85, scale: 0.8, jump: false },
    FR: { z: 0.14, splay: 0.85, scale: 0.8, jump: false },
    ML: { z: -0.02, splay: 1.0, scale: 0.9, jump: false },
    MR: { z: -0.02, splay: 1.0, scale: 0.9, jump: false },
    BL: { z: -0.16, splay: 1.05, scale: 1.0, jump: true },
    BR: { z: -0.16, splay: 1.05, scale: 1.0, jump: true },
  };

  for (const leg of INSECT_LEGS) {
    const spec = legSpec[leg];
    const side = leg.endsWith('L') ? -1 : 1;
    const s = spec.scale;

    rb.joint(`coxa${leg}`, [side * 0.13, -0.03, spec.z], 'thorax');
    rb.joint(`femur${leg}`, [side * 0.05, 0, 0], `coxa${leg}`);
    rb.joint(`tibia${leg}`, [0, -(spec.jump ? 0.3 : 0.2) * s, 0], `femur${leg}`);
    rb.joint(`tarsus${leg}`, [0, -(spec.jump ? 0.32 : 0.22) * s, 0], `tibia${leg}`);

    // Femur angles up and outward from the body; the jumping pair is a thick
    // muscular wedge rather than a stick.
    const femurGeo = spec.jump
      ? profileMesh(
          [
            { y: 0.03, rx: 0.055, rz: 0.06 },
            { y: -0.07, rx: 0.075, rz: 0.085 },
            { y: -0.18, rx: 0.055, rz: 0.062 },
            { y: -0.3, rx: 0.026, rz: 0.03 },
          ],
          5,
        )
      : profileMesh(
          [
            { y: 0.02, rx: 0.032, rz: 0.034 },
            { y: -0.09, rx: 0.028, rz: 0.03 },
            { y: -0.2, rx: 0.019, rz: 0.021 },
          ],
          4,
        );
    rb.attach(`femur${leg}`, femurGeo, spec.jump ? body : dark, { scale: s });

    rb.attach(
      `tibia${leg}`,
      profileMesh(
        [
          { y: 0.01, rx: 0.024, rz: 0.026 },
          { y: -0.16, rx: 0.017, rz: 0.019 },
          { y: -0.32, rx: 0.011, rz: 0.013 },
        ],
        4,
      ),
      dark,
      { scale: s },
    );
    // Tibial spines — the detail that makes a grasshopper leg read as one.
    if (spec.jump) {
      for (let i = 0; i < 4; i++) {
        rb.attach(`tibia${leg}`, profileMesh([{ y: 0, rx: 0.008, rz: 0.008 }, { y: -0.035, rx: 0.001, rz: 0.001 }], 3), accent, {
          position: [0, -0.06 - i * 0.06, -0.016],
          rotation: [-0.9, 0, 0],
          scale: s,
        });
      }
    }

    rb.attach(
      `tarsus${leg}`,
      mergeAll([
        { geo: profileMesh([{ y: 0, rx: 0.014, rz: 0.014 }, { y: -0.05, rx: 0.009, rz: 0.03 }], 4) },
        { geo: shapedBox(0.02, 0.012, 0.055), matrix: transform([0, -0.055, 0.018]) },
      ]),
      dark,
      { scale: s },
    );

    // Bind pose: femur out and up, tibia folded back down.
    rb.joints.get(`coxa${leg}`)!.rotation.set(0, 0, side * spec.splay * 0.55);
    rb.joints.get(`femur${leg}`)!.rotation.set(spec.jump ? -0.45 : -0.1, 0, side * spec.splay * 0.5);
    rb.joints.get(`tibia${leg}`)!.rotation.set(spec.jump ? 1.5 : 0.75, 0, side * -0.3);
    rb.joints.get(`tarsus${leg}`)!.rotation.set(-0.6, 0, 0);
  }

  const rig = rb.build('insect', 0.95 * visual.scale, 0.44 * visual.scale);
  rig.root.scale.setScalar(visual.scale);
  return rig;
}

function buildSegmentedAbdomen(): THREE.BufferGeometry {
  const parts: { geo: THREE.BufferGeometry; matrix?: THREE.Matrix4 }[] = [];
  const segments = 5;
  for (let i = 0; i < segments; i++) {
    const t = i / (segments - 1);
    const r = 0.16 * (1 - t * 0.72);
    parts.push({
      geo: profileMesh(
        [
          { y: 0.035, rx: r * 0.94, rz: r * 0.9 },
          { y: 0, rx: r, rz: r * 0.96 },
          { y: -0.035, rx: r * 0.9, rz: r * 0.86 },
        ],
        6,
      ),
      // Gaps between plates: a smooth taper reads as a carrot, not a body.
      matrix: transform([0, 0.01 - t * 0.05, -i * 0.078], [Math.PI / 2, 0, 0]),
    });
  }
  return mergeAll(parts);
}

function buildAntenna(): THREE.BufferGeometry {
  const parts: { geo: THREE.BufferGeometry; matrix?: THREE.Matrix4 }[] = [];
  let y = 0;
  for (let i = 0; i < 4; i++) {
    const len = 0.085 - i * 0.012;
    const r = 0.009 - i * 0.0016;
    parts.push({
      geo: profileMesh([{ y: 0, rx: r, rz: r }, { y: len, rx: r * 0.8, rz: r * 0.8 }], 3),
      // Each segment kinks slightly, so the antenna curves instead of spiking.
      matrix: transform([0, y, i * 0.012], [i * 0.14, 0, 0]),
    });
    y += len * 0.94;
  }
  return mergeAll(parts);
}

/**
 * Rockhide Sentinel: a heavy stone biped. Uses humanoid joint names so it can
 * share the blending machinery, but with brutally different proportions —
 * long arms, short legs, no neck, mass carried forward.
 */
function buildGolem(mats: MaterialFactory, visual: EnemyVisual): Rig {
  const rb = new RigBuilder();
  const stone = mats.toon(visual.color);
  const darkStone = mats.toon(0x5f4736);
  const moss = mats.toon(0x4e7a3c);
  const core = mats.toon(visual.accent, 0.7);

  rb.joint('root', [0, 0, 0]);
  rb.joint('hips', [0, 0.78, 0], 'root');
  rb.joint('spine', [0, 0.06, 0], 'hips');
  rb.joint('chest', [0, 0.26, 0], 'spine');
  rb.joint('neck', [0, 0.34, 0.02], 'chest');
  rb.joint('head', [0, 0.06, 0.02], 'neck');

  rb.attach('hips', profileMesh(
    [
      { y: 0.06, rx: 0.24, rz: 0.19 },
      { y: -0.08, rx: 0.27, rz: 0.21 },
      { y: -0.2, rx: 0.22, rz: 0.18 },
    ], 6), darkStone);

  // Chest is a huge slab that overhangs the hips — the bruiser silhouette.
  rb.attach('spine', profileMesh(
    [
      { y: 0.42, rx: 0.44, rz: 0.26 },
      { y: 0.3, rx: 0.46, rz: 0.28 },
      { y: 0.12, rx: 0.36, rz: 0.24 },
      { y: 0, rx: 0.26, rz: 0.2 },
    ], 7), stone);

  // Cracked plates layered over the chest, with the glowing core between them.
  for (let i = 0; i < 3; i++) {
    rb.attach('chest', shapedBox(0.3 - i * 0.05, 0.09, 0.12, { topScale: 0.8 }), darkStone, {
      position: [(i - 1) * 0.13, 0.1 - i * 0.03, 0.2],
      rotation: [0.1, (i - 1) * 0.25, (i - 1) * 0.12],
    });
  }
  rb.attach('chest', profileMesh(
    [
      { y: 0.06, rx: 0.05, rz: 0.03 },
      { y: 0, rx: 0.08, rz: 0.045 },
      { y: -0.07, rx: 0.045, rz: 0.028 },
    ], 5), core, { position: [0, 0.04, 0.24] });

  // Head sunk between the shoulders, no visible neck.
  rb.attach('head', profileMesh(
    [
      { y: 0.11, rx: 0.11, rz: 0.11 },
      { y: 0.03, rx: 0.16, rz: 0.16 },
      { y: -0.06, rx: 0.15, rz: 0.155 },
      { y: -0.12, rx: 0.1, rz: 0.11 },
    ], 6), stone);
  rb.attach('head', shapedBox(0.3, 0.07, 0.13, { topScale: 0.7 }), darkStone, {
    position: [0, 0.075, 0.05],
    rotation: [-0.2, 0, 0],
  });
  for (const side of [-1, 1] as const) {
    rb.attach('head', profileMesh([{ y: 0, rx: 0.026, rz: 0.02 }, { y: -0.02, rx: 0.016, rz: 0.013 }], 4), core, {
      position: [side * 0.06, 0.005, 0.135],
    });
    // Horn shards angled back off the skull.
    rb.attach('head', profileMesh(
      [
        { y: 0, rx: 0.035, rz: 0.032 },
        { y: 0.11, rx: 0.02, rz: 0.019 },
        { y: 0.19, rx: 0.004, rz: 0.004 },
      ], 4), darkStone, { position: [side * 0.12, 0.06, -0.03], rotation: [-0.5, 0, side * 0.5] });
  }
  rb.attach('head', shapedBox(0.2, 0.05, 0.1), moss, { position: [0.02, 0.11, -0.03], rotation: [0.2, 0.3, 0] });

  // ------------------------------------------------------------- arms
  for (const side of [-1, 1] as const) {
    const S = side < 0 ? 'L' : 'R';
    rb.joint(`shoulder${S}`, [side * 0.4, 0.28, 0], 'chest');
    rb.joint(`arm${S}`, [side * 0.12, 0, 0], `shoulder${S}`);
    rb.joint(`forearm${S}`, [0, -0.42, 0], `arm${S}`);
    rb.joint(`hand${S}`, [0, -0.4, 0], `forearm${S}`);

    rb.attach(`shoulder${S}`, profileMesh(
      [
        { y: 0.13, rx: 0.15, rz: 0.15 },
        { y: 0.02, rx: 0.21, rz: 0.2 },
        { y: -0.12, rx: 0.16, rz: 0.16 },
      ], 6), stone);
    // Pauldron shards.
    for (let i = 0; i < 3; i++) {
      rb.attach(`shoulder${S}`, profileMesh(
        [
          { y: 0, rx: 0.06, rz: 0.05 },
          { y: 0.13, rx: 0.025, rz: 0.022 },
        ], 4), darkStone, { position: [side * (0.06 + i * 0.05), 0.07 - i * 0.03, (i - 1) * 0.09], rotation: [0, 0, side * (0.3 + i * 0.25)] });
    }

    rb.attach(`arm${S}`, profileMesh(
      [
        { y: 0.02, rx: 0.13, rz: 0.13 },
        { y: -0.16, rx: 0.14, rz: 0.14 },
        { y: -0.32, rx: 0.115, rz: 0.115 },
        { y: -0.42, rx: 0.1, rz: 0.1 },
      ], 6), stone);
    // Forearm flares outward toward a huge fist.
    rb.attach(`forearm${S}`, profileMesh(
      [
        { y: 0, rx: 0.11, rz: 0.11 },
        { y: -0.16, rx: 0.135, rz: 0.135 },
        { y: -0.32, rx: 0.155, rz: 0.15 },
        { y: -0.4, rx: 0.14, rz: 0.14 },
      ], 6), stone);
    rb.attach(`forearm${S}`, profileMesh([{ y: -0.2, rx: 0.02, rz: 0.02 }, { y: -0.34, rx: 0.02, rz: 0.02 }], 4), core, {
      position: [side * 0.11, 0, 0.04],
    });

    rb.attach(`hand${S}`, buildGolemFist(), stone);
  }

  // ------------------------------------------------------------- legs
  for (const side of [-1, 1] as const) {
    const S = side < 0 ? 'L' : 'R';
    rb.joint(`thigh${S}`, [side * 0.16, -0.18, 0], 'hips');
    rb.joint(`shin${S}`, [0, -0.3, 0], `thigh${S}`);
    rb.joint(`foot${S}`, [0, -0.28, 0], `shin${S}`);

    rb.attach(`thigh${S}`, profileMesh(
      [
        { y: 0.03, rx: 0.15, rz: 0.16 },
        { y: -0.12, rx: 0.155, rz: 0.17 },
        { y: -0.3, rx: 0.12, rz: 0.13 },
      ], 6), stone);
    rb.attach(`shin${S}`, profileMesh(
      [
        { y: 0, rx: 0.125, rz: 0.13 },
        { y: -0.12, rx: 0.14, rz: 0.15, oz: -0.02 },
        { y: -0.28, rx: 0.11, rz: 0.12 },
      ], 6), stone);
    rb.attach(`foot${S}`, mergeAll([
      { geo: profileMesh([{ y: 0, rx: 0.15, rz: 0.16 }, { y: -0.12, rx: 0.17, rz: 0.22, oz: 0.05 }], 6) },
      { geo: shapedBox(0.3, 0.07, 0.13), matrix: transform([0, -0.13, 0.2]) },
      { geo: shapedBox(0.2, 0.08, 0.1), matrix: transform([0, -0.09, -0.12]) },
    ]), darkStone);
  }

  const rig = rb.build('golem', 2.3 * visual.scale, 0.78 * visual.scale);
  rig.root.scale.setScalar(visual.scale);
  return rig;
}

function buildGolemFist(): THREE.BufferGeometry {
  const parts: { geo: THREE.BufferGeometry; matrix?: THREE.Matrix4 }[] = [];
  parts.push({
    geo: profileMesh(
      [
        { y: 0, rx: 0.14, rz: 0.14 },
        { y: -0.11, rx: 0.17, rz: 0.16 },
        { y: -0.22, rx: 0.13, rz: 0.13 },
      ],
      6,
    ),
  });
  // Knuckle boulders, deliberately uneven.
  for (let i = 0; i < 4; i++) {
    const r = 0.05 + (i % 2) * 0.012;
    parts.push({
      geo: profileMesh([{ y: 0, rx: r, rz: r }, { y: -0.06, rx: r * 0.8, rz: r * 0.8 }], 4),
      matrix: transform([-0.075 + i * 0.05, -0.09, 0.13], [0.5, i * 0.4, 0]),
    });
  }
  return mergeAll(parts);
}

/**
 * Warden Zhun: tall, robed, four-armed silhouette suggested by a wide mantle.
 * Robed characters are mostly about the skirt, so the robe is built as
 * separate hanging panels that the animator can sway independently.
 */
function buildWarden(mats: MaterialFactory, visual: EnemyVisual): Rig {
  const rb = new RigBuilder();
  const robe = mats.toon(visual.color);
  const robeDark = mats.toon(0x2c6f8a);
  const glow = mats.toon(visual.accent, 0.85);
  const skin = mats.toon(0x9fd8e8);
  const gold = mats.toon(0xe8c46a, 0.25);

  rb.joint('root', [0, 0, 0]);
  rb.joint('hips', [0, 1.05, 0], 'root');
  rb.joint('spine', [0, 0.08, 0], 'hips');
  rb.joint('chest', [0, 0.34, 0], 'spine');
  rb.joint('neck', [0, 0.36, 0], 'chest');
  rb.joint('head', [0, 0.13, 0], 'neck');
  rb.joint('halo', [0, 0.42, 0], 'head');

  // Six robe panels on their own joints so the skirt can sway and trail.
  const PANELS = 6;
  for (let i = 0; i < PANELS; i++) {
    const a = (i / PANELS) * Math.PI * 2;
    rb.joint(`robe${i}`, [Math.sin(a) * 0.2, -0.06, Math.cos(a) * 0.2], 'hips');
    rb.joints.get(`robe${i}`)!.rotation.set(0, a, 0);
    rb.attach(`robe${i}`, profileMesh(
      [
        { y: 0, rx: 0.15, rz: 0.07 },
        { y: -0.35, rx: 0.19, rz: 0.09, oz: 0.03 },
        { y: -0.72, rx: 0.24, rz: 0.11, oz: 0.07 },
        { y: -0.98, rx: 0.2, rz: 0.09, oz: 0.09 },
      ], 4), i % 2 === 0 ? robe : robeDark);
  }

  rb.attach('hips', profileMesh(
    [
      { y: 0.06, rx: 0.19, rz: 0.15 },
      { y: -0.06, rx: 0.23, rz: 0.18 },
    ], 6), robe);
  rb.attach('hips', profileMesh([{ y: 0.02, rx: 0.26, rz: 0.2 }, { y: -0.05, rx: 0.24, rz: 0.19 }], 6), gold);

  rb.attach('spine', profileMesh(
    [
      { y: 0.4, rx: 0.24, rz: 0.16 },
      { y: 0.26, rx: 0.26, rz: 0.17 },
      { y: 0.1, rx: 0.21, rz: 0.145 },
      { y: 0, rx: 0.18, rz: 0.13 },
    ], 7), robe);

  // Mantle: a wide flared collar that reads as authority from any angle.
  rb.attach('chest', profileMesh(
    [
      { y: 0.14, rx: 0.2, rz: 0.15 },
      { y: 0.04, rx: 0.42, rz: 0.28 },
      { y: -0.06, rx: 0.46, rz: 0.31 },
    ], 7), robeDark, { position: [0, 0.06, 0] });
  rb.attach('chest', profileMesh(
    [
      { y: 0.1, rx: 0.05, rz: 0.03 },
      { y: 0, rx: 0.09, rz: 0.05 },
      { y: -0.1, rx: 0.04, rz: 0.025 },
    ], 5), glow, { position: [0, 0.06, 0.15] });

  rb.attach('head', profileMesh(
    [
      { y: 0.13, rx: 0.06, rz: 0.06 },
      { y: 0.06, rx: 0.115, rz: 0.115 },
      { y: -0.03, rx: 0.125, rz: 0.13 },
      { y: -0.12, rx: 0.08, rz: 0.095 },
    ], 6), skin);
  // Faceplate: no eyes, just a glowing band. Reads as inhuman instantly.
  rb.attach('head', shapedBox(0.19, 0.045, 0.03), glow, { position: [0, 0.01, 0.108] });
  rb.attach('head', profileMesh(
    [
      { y: 0.18, rx: 0.04, rz: 0.04 },
      { y: 0.06, rx: 0.13, rz: 0.135 },
      { y: -0.06, rx: 0.135, rz: 0.14 },
    ], 6), gold, { position: [0, 0.03, -0.015] });
  for (const side of [-1, 1] as const) {
    rb.attach('head', profileMesh(
      [
        { y: 0, rx: 0.03, rz: 0.028 },
        { y: 0.16, rx: 0.016, rz: 0.015 },
        { y: 0.28, rx: 0.003, rz: 0.003 },
      ], 4), gold, { position: [side * 0.1, 0.06, -0.02], rotation: [-0.35, 0, side * 0.42] });
  }

  rb.attach('halo', buildHalo(), glow);

  for (const side of [-1, 1] as const) {
    const S = side < 0 ? 'L' : 'R';
    rb.joint(`shoulder${S}`, [side * 0.24, 0.28, 0], 'chest');
    rb.joint(`arm${S}`, [side * 0.08, 0, 0], `shoulder${S}`);
    rb.joint(`forearm${S}`, [0, -0.36, 0], `arm${S}`);
    rb.joint(`hand${S}`, [0, -0.33, 0], `forearm${S}`);

    rb.attach(`shoulder${S}`, profileMesh(
      [
        { y: 0.08, rx: 0.1, rz: 0.1 },
        { y: -0.06, rx: 0.13, rz: 0.125 },
      ], 6), robeDark);
    // Wide hanging sleeve, not a bare arm.
    rb.attach(`arm${S}`, profileMesh(
      [
        { y: 0.02, rx: 0.1, rz: 0.1 },
        { y: -0.18, rx: 0.115, rz: 0.115 },
        { y: -0.36, rx: 0.135, rz: 0.13 },
      ], 6), robe);
    rb.attach(`forearm${S}`, profileMesh(
      [
        { y: 0, rx: 0.125, rz: 0.12 },
        { y: -0.18, rx: 0.15, rz: 0.14 },
        { y: -0.33, rx: 0.16, rz: 0.15 },
      ], 6), robeDark);
    rb.attach(`hand${S}`, buildHand(1.35, 0.35), skin);
    rb.attach(`hand${S}`, profileMesh([{ y: 0.02, rx: 0.07, rz: 0.05 }, { y: -0.04, rx: 0.075, rz: 0.055 }], 5), gold);
  }

  // Legs exist but stay hidden under the robe — they still drive the stride,
  // which is what makes the panels swing correctly.
  for (const side of [-1, 1] as const) {
    const S = side < 0 ? 'L' : 'R';
    rb.joint(`thigh${S}`, [side * 0.11, -0.1, 0], 'hips');
    rb.joint(`shin${S}`, [0, -0.44, 0], `thigh${S}`);
    rb.joint(`foot${S}`, [0, -0.42, 0], `shin${S}`);
    rb.attach(`thigh${S}`, profileMesh([{ y: 0, rx: 0.09, rz: 0.09 }, { y: -0.44, rx: 0.07, rz: 0.07 }], 5), robeDark);
    rb.attach(`shin${S}`, profileMesh([{ y: 0, rx: 0.07, rz: 0.07 }, { y: -0.42, rx: 0.055, rz: 0.06 }], 5), robeDark);
    rb.attach(`foot${S}`, buildFoot(1.15), gold);
  }

  const rig = rb.build('warden', 2.5 * visual.scale, 1.05 * visual.scale);
  rig.root.scale.setScalar(visual.scale);
  return rig;
}

/** Broken ring of floating shards rather than a solid torus. */
function buildHalo(): THREE.BufferGeometry {
  const parts: { geo: THREE.BufferGeometry; matrix?: THREE.Matrix4 }[] = [];
  const shards = 7;
  for (let i = 0; i < shards; i++) {
    const a = (i / shards) * Math.PI * 2;
    const r = 0.34;
    const len = 0.1 + (i % 3) * 0.03;
    parts.push({
      geo: profileMesh(
        [
          { y: -len / 2, rx: 0.012, rz: 0.022 },
          { y: 0, rx: 0.02, rz: 0.034 },
          { y: len / 2, rx: 0.008, rz: 0.016 },
        ],
        4,
      ),
      matrix: transform([Math.sin(a) * r, 0, Math.cos(a) * r], [0, a, Math.PI / 2 + i * 0.2]),
    });
  }
  return mergeAll(parts);
}
