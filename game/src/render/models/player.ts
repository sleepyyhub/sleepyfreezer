import * as THREE from 'three';
import type { MaterialFactory } from '../materials/toon';
import { RigBuilder, type Rig } from './skeleton';
import {
  orientTo,
  buildFoot,
  buildHand,
  buildHead,
  buildPelvis,
  buildTorso,
  mergeAll,
  profileMesh,
  shapedBox,
  transform,
} from './geom';

/**
 * The player: a martial artist in a weighted gi. Anime proportions — roughly
 * 6.5 heads tall with an oversized hair silhouette, since at this facet
 * density silhouette carries the entire read.
 *
 * Limb geometry hangs off joints at anatomically correct pivots, and each
 * segment is a lofted profile with real muscle taper rather than a box.
 */
export function buildPlayerRig(mats: MaterialFactory): Rig {
  const rb = new RigBuilder();

  const skin = mats.toon(0xf2cfa8);
  const gi = mats.toon(0xdd5f3a);
  const giDark = mats.toon(0xb44528);
  const trim = mats.toon(0xf7f2e4);
  const hairMat = mats.toon(0x241f2e);
  const belt = mats.toon(0x2f3a4a);
  const eyeMat = mats.toon(0x141822);

  // ------------------------------------------------------------- spine
  rb.joint('root', [0, 0, 0]);
  rb.joint('hips', [0, 0.92, 0], 'root');
  rb.joint('spine', [0, 0.02, 0], 'hips');
  rb.joint('chest', [0, 0.24, 0], 'spine');
  rb.joint('neck', [0, 0.44, 0.008], 'chest');
  rb.joint('head', [0, 0.075, 0], 'neck');
  rb.joint('hair', [0, 0.1, -0.01], 'head');

  rb.attach('hips', buildPelvis(0.148, 0.098, 0.17), gi, { position: [0, 0.02, 0] });
  rb.attach('hips', shapedBox(0.31, 0.055, 0.215, { topScale: 1.03 }), belt, {
    position: [0, 0.045, 0],
  });
  // Belt knot and tails — small asymmetric details read as handmade.
  rb.attach('hips', shapedBox(0.075, 0.07, 0.055), belt, { position: [0.02, 0.035, 0.11] });
  rb.attach(
    'hips',
    mergeAll([
      { geo: shapedBox(0.05, 0.26, 0.028, { bottomScale: 0.6 }), matrix: transform([-0.03, -0.12, 0.005], [0.1, 0, 0.09]) },
      { geo: shapedBox(0.045, 0.21, 0.026, { bottomScale: 0.6 }), matrix: transform([0.045, -0.1, 0.01], [0.05, 0, -0.13]) },
    ]),
    belt,
    { position: [0, 0.02, 0.115] },
  );

  rb.attach('spine', buildTorso({ shoulderW: 0.2, chestD: 0.115, waistW: 0.132, height: 0.44 }), gi);
  // Open gi lapels crossing the chest.
  for (const side of [-1, 1] as const) {
    rb.attach(
      'chest',
      shapedBox(0.075, 0.4, 0.035, { topScale: 1.25, bottomScale: 0.75 }),
      trim,
      { position: [side * 0.062, -0.06, 0.104], rotation: [0.06, 0, side * 0.16] },
    );
  }
  rb.attach('chest', shapedBox(0.26, 0.09, 0.05, { topScale: 0.85 }), giDark, {
    position: [0, 0.16, 0.088],
    rotation: [0.18, 0, 0],
  });

  // ------------------------------------------------------------- head
  rb.attach('head', buildHead(1.16), skin);

  // Eyes on a flat plane — modelled eyes never work at this poly count.
  for (const side of [-1, 1] as const) {
    rb.attach('head', shapedBox(0.042, 0.05, 0.012), eyeMat, {
      position: [side * 0.048, -0.008, 0.107],
      rotation: [0, side * -0.12, side * 0.12],
    });
  }
  rb.attach('head', shapedBox(0.055, 0.012, 0.01), hairMat, {
    position: [-0.05, 0.038, 0.104],
    rotation: [0, 0, -0.2],
  });
  rb.attach('head', shapedBox(0.055, 0.012, 0.01), hairMat, {
    position: [0.05, 0.038, 0.104],
    rotation: [0, 0, 0.2],
  });
  for (const side of [-1, 1] as const) {
    rb.attach('head', profileMesh([{ y: 0.03, rx: 0.016, rz: 0.03 }, { y: -0.03, rx: 0.012, rz: 0.022 }], 4), skin, {
      position: [side * 0.112, -0.01, 0.005],
    });
  }

  // Hair: a swept crown of spikes plus a fringe. Parented to its own joint so
  // it can lag behind the head on every clip.
  rb.attach('hair', buildHairCrown(), hairMat);

  // ------------------------------------------------------------- arms
  for (const side of [-1, 1] as const) {
    const S = side < 0 ? 'L' : 'R';
    rb.joint(`shoulder${S}`, [side * 0.088, 0.395, 0], 'chest');
    rb.joint(`arm${S}`, [side * 0.072, 0, 0], `shoulder${S}`);
    rb.joint(`forearm${S}`, [0, -0.27, 0], `arm${S}`);
    rb.joint(`hand${S}`, [0, -0.245, 0], `forearm${S}`);

    // Deltoid cap over the shoulder joint hides the seam when the arm lifts.
    rb.attach(`shoulder${S}`, profileMesh(
      [
        { y: 0.055, rx: 0.062, rz: 0.062 },
        { y: 0.0, rx: 0.082, rz: 0.078 },
        { y: -0.06, rx: 0.068, rz: 0.066 },
      ], 6), gi, { position: [side * 0.012, 0.005, 0] });

    // Upper arm: biceps swell at a third of the way down, taper into the elbow.
    rb.attach(`arm${S}`, profileMesh(
      [
        { y: 0, rx: 0.062, rz: 0.06 },
        { y: -0.09, rx: 0.067, rz: 0.064, oz: 0.006 },
        { y: -0.18, rx: 0.055, rz: 0.054 },
        { y: -0.27, rx: 0.044, rz: 0.046 },
      ], 6), skin);
    // Gi sleeve, cut above the elbow.
    rb.attach(`arm${S}`, profileMesh(
      [
        { y: 0.035, rx: 0.078, rz: 0.076 },
        { y: -0.1, rx: 0.073, rz: 0.071 },
        { y: -0.19, rx: 0.06, rz: 0.06 },
        { y: -0.205, rx: 0.052, rz: 0.053 },
      ], 6), gi);

    // Forearm: broad at the elbow, narrow at the wrist, with a slight twist.
    rb.attach(`forearm${S}`, profileMesh(
      [
        { y: 0, rx: 0.048, rz: 0.05 },
        { y: -0.07, rx: 0.05, rz: 0.052, oz: 0.004 },
        { y: -0.16, rx: 0.037, rz: 0.04, twist: side * 0.15 },
        { y: -0.225, rx: 0.028, rz: 0.033, twist: side * 0.2 },
      ], 6), skin);
    // Hand wraps.
    rb.attach(`forearm${S}`, profileMesh(
      [
        { y: -0.1, rx: 0.054, rz: 0.056 },
        { y: -0.19, rx: 0.04, rz: 0.043 },
        { y: -0.235, rx: 0.033, rz: 0.037 },
      ], 6), trim);

    rb.attach(`hand${S}`, buildHand(1.0, 0.5), skin, { rotation: [0, 0, side * -0.06] });
    rb.attach(`hand${S}`, profileMesh([{ y: 0.01, rx: 0.055, rz: 0.036 }, { y: -0.055, rx: 0.06, rz: 0.038 }], 6), trim);
  }

  // ------------------------------------------------------------- legs
  for (const side of [-1, 1] as const) {
    const S = side < 0 ? 'L' : 'R';
    rb.joint(`thigh${S}`, [side * 0.082, -0.13, 0], 'hips');
    rb.joint(`shin${S}`, [0, -0.4, 0], `thigh${S}`);
    rb.joint(`foot${S}`, [0, -0.38, 0], `shin${S}`);

    // Thigh: quad mass high and forward, tapering to a narrow knee.
    rb.attach(`thigh${S}`, profileMesh(
      [
        { y: 0.02, rx: 0.085, rz: 0.088 },
        { y: -0.12, rx: 0.088, rz: 0.092, oz: 0.008 },
        { y: -0.26, rx: 0.072, rz: 0.076 },
        { y: -0.4, rx: 0.058, rz: 0.062 },
      ], 6), gi);

    // Calf bulge sits high and to the rear; without the oz offset a leg reads
    // as a traffic cone.
    rb.attach(`shin${S}`, profileMesh(
      [
        { y: 0, rx: 0.058, rz: 0.06 },
        { y: -0.09, rx: 0.062, rz: 0.07, oz: -0.014 },
        { y: -0.22, rx: 0.043, rz: 0.05, oz: -0.006 },
        { y: -0.35, rx: 0.034, rz: 0.038 },
      ], 6), gi);
    // Trouser cuff, tied above the ankle.
    rb.attach(`shin${S}`, profileMesh(
      [
        { y: -0.24, rx: 0.058, rz: 0.062 },
        { y: -0.3, rx: 0.05, rz: 0.053 },
      ], 6), giDark);

    rb.attach(`foot${S}`, buildFoot(1.0), trim);
  }

  const rig = rb.build('humanoid', 1.86, 0.92);
  return rig;
}

/**
 * Swept-back spike crown. Spikes are generated on a ring with varying length
 * and a consistent backward sweep; evenly-sized spikes read as a sea urchin.
 */
function buildHairCrown(): THREE.BufferGeometry {
  const parts: { geo: THREE.BufferGeometry; matrix?: THREE.Matrix4 }[] = [];

  // Skull cap so the scalp is never visible between spikes.
  parts.push({
    geo: profileMesh(
      [
        { y: 0.075, rx: 0.07, rz: 0.075, oz: -0.015 },
        { y: 0.03, rx: 0.114, rz: 0.118, oz: -0.012 },
        { y: -0.02, rx: 0.125, rz: 0.128, oz: -0.008 },
        { y: -0.07, rx: 0.118, rz: 0.124, oz: -0.004 },
      ],
      7,
    ),
  });

  // Two rings of spikes. Each one is aimed at an explicit direction that mixes
  // "outward from the skull" with a constant backward sweep — the sweep is
  // what turns a sea urchin into a hairstyle.
  const rings = [
    { count: 8, radius: 0.095, height: 0.0, outward: 0.95, lift: 0.75, len: 0.1 },
    { count: 5, radius: 0.055, height: 0.055, outward: 0.5, lift: 1.0, len: 0.13 },
  ];

  for (let r = 0; r < rings.length; r++) {
    const ring = rings[r];
    for (let i = 0; i < ring.count; i++) {
      const a = (i / ring.count) * Math.PI * 2 + r * 0.4;
      const sin = Math.sin(a);
      const cos = Math.cos(a);
      // 1 at the back of the head, 0 at the front.
      const back = (1 - cos) / 2;

      // Front spikes stay short and lie flatter; back spikes are long and lift.
      const len = ring.len * (0.7 + back * 0.9) + (i % 3) * 0.012;

      const dir = new THREE.Vector3(
        sin * ring.outward,
        ring.lift * (0.55 + back * 0.5),
        cos * ring.outward - 0.85, // constant backward sweep
      );

      parts.push({
        geo: profileMesh(
          [
            { y: 0, rx: 0.032, rz: 0.026 },
            { y: len * 0.5, rx: 0.021, rz: 0.017 },
            { y: len, rx: 0.003, rz: 0.003 },
          ],
          4,
        ),
        matrix: orientTo(dir, [sin * ring.radius, ring.height, cos * ring.radius], 1, a),
      });
    }
  }

  // Fringe: three flat locks over the forehead, angled differently.
  const fringeAngles = [-0.5, 0.05, 0.45];
  for (let i = 0; i < fringeAngles.length; i++) {
    const lock = profileMesh(
      [
        { y: 0.02, rx: 0.042, rz: 0.018 },
        { y: -0.05, rx: 0.036, rz: 0.016 },
        { y: -0.1, rx: 0.014, rz: 0.01 },
      ],
      4,
    );
    parts.push({
      geo: lock,
      matrix: transform(
        [fringeAngles[i] * 0.11, -0.03, 0.098],
        [0.28, 0, fringeAngles[i] * 0.7],
      ),
    });
  }

  return mergeAll(parts);
}
