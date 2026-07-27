import * as THREE from 'three';
import type { MaterialFactory } from '../materials/toon';

export interface CharacterRig {
  root: THREE.Group;
  /** Parts the animator poses. Named, not indexed, so poses stay readable. */
  torso: THREE.Object3D;
  head: THREE.Object3D;
  armL: THREE.Object3D;
  armR: THREE.Object3D;
  legL: THREE.Object3D;
  legR: THREE.Object3D;
  weapon: THREE.Object3D | null;
  height: number;
}

/**
 * Procedural stand-in rigs. These occupy the slot a rigged GLB would fill:
 * `CharacterRig` is the contract the animator codes against, so swapping in
 * real art means replacing this factory and nothing else.
 */
export function buildPlayerRig(mats: MaterialFactory): CharacterRig {
  const root = new THREE.Group();

  const skin = mats.toon(0xf0c9a0);
  const gi = mats.toon(0xe8683f);
  const trim = mats.toon(0xf5f0e0);
  const hair = mats.toon(0x2b2b38);

  const torso = new THREE.Group();
  const torsoMesh = new THREE.Mesh(taperedBox(0.62, 0.8, 0.36, 0.78), gi);
  torsoMesh.position.y = 0.4;
  torso.add(torsoMesh);
  const sash = new THREE.Mesh(new THREE.BoxGeometry(0.68, 0.14, 0.4), trim);
  sash.position.y = 0.08;
  torso.add(sash);
  torso.position.y = 0.92;

  const head = new THREE.Group();
  const headMesh = new THREE.Mesh(new THREE.BoxGeometry(0.44, 0.44, 0.42), skin);
  head.add(headMesh);
  // Oversized hair volume is most of what makes a low-poly head read as anime.
  const hairMesh = new THREE.Mesh(new THREE.ConeGeometry(0.42, 0.62, 6), hair);
  hairMesh.position.y = 0.36;
  hairMesh.rotation.y = Math.PI / 6;
  head.add(hairMesh);
  const fringe = new THREE.Mesh(new THREE.BoxGeometry(0.46, 0.16, 0.1), hair);
  fringe.position.set(0, 0.18, 0.2);
  head.add(fringe);
  head.position.y = 0.48;
  torso.add(head);

  const mkArm = (side: number) => {
    const g = new THREE.Group();
    const upper = new THREE.Mesh(new THREE.BoxGeometry(0.18, 0.44, 0.18), gi);
    upper.position.y = -0.22;
    const fore = new THREE.Mesh(new THREE.BoxGeometry(0.16, 0.4, 0.16), skin);
    fore.position.y = -0.6;
    const fist = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.2, 0.2), skin);
    fist.position.y = -0.86;
    g.add(upper, fore, fist);
    g.position.set(side * 0.33, 0.66, 0);
    torso.add(g);
    return g;
  };
  const armL = mkArm(-1);
  const armR = mkArm(1);

  const mkLeg = (side: number) => {
    const g = new THREE.Group();
    const thigh = new THREE.Mesh(new THREE.BoxGeometry(0.22, 0.46, 0.22), gi);
    thigh.position.y = -0.23;
    const shin = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.44, 0.2), gi);
    shin.position.y = -0.66;
    const foot = new THREE.Mesh(new THREE.BoxGeometry(0.24, 0.14, 0.34), trim);
    foot.position.set(0, -0.92, 0.06);
    g.add(thigh, shin, foot);
    g.position.set(side * 0.17, 0, 0);
    torso.add(g);
    return g;
  };
  const legL = mkLeg(-1);
  const legR = mkLeg(1);

  root.add(torso);
  root.traverse((o) => {
    if ((o as THREE.Mesh).isMesh) {
      o.castShadow = true;
      o.receiveShadow = false;
    }
  });

  return { root, torso, head, armL, armR, legL, legR, weapon: null, height: 1.85 };
}

export function buildEnemyRig(
  mats: MaterialFactory,
  visual: { color: number; accent: number; scale: number; shape: string },
): CharacterRig {
  const root = new THREE.Group();
  const body = mats.toon(visual.color);
  const accent = mats.toon(visual.accent, visual.shape === 'warden' ? 0.5 : 0.2);

  const torso = new THREE.Group();
  const head = new THREE.Group();
  let height = 1.6;

  if (visual.shape === 'insectoid') {
    const abdomen = new THREE.Mesh(new THREE.IcosahedronGeometry(0.42, 0), body);
    abdomen.scale.set(1.1, 0.8, 1.5);
    torso.add(abdomen);
    const headMesh = new THREE.Mesh(new THREE.OctahedronGeometry(0.26, 0), accent);
    headMesh.position.set(0, 0.1, 0.5);
    head.add(headMesh);
    for (const s of [-1, 1]) {
      const antenna = new THREE.Mesh(new THREE.ConeGeometry(0.05, 0.4, 4), accent);
      antenna.position.set(s * 0.12, 0.3, 0.55);
      antenna.rotation.z = s * 0.4;
      head.add(antenna);
    }
    torso.add(head);
    torso.position.y = 0.5;
    height = 1.0;
  } else if (visual.shape === 'golem') {
    const core = new THREE.Mesh(taperedBox(0.9, 1.0, 0.7, 1.15), body);
    core.position.y = 0.5;
    torso.add(core);
    const headMesh = new THREE.Mesh(new THREE.IcosahedronGeometry(0.34, 0), body);
    headMesh.position.y = 1.2;
    head.add(headMesh);
    torso.add(head);
    for (const s of [-1, 1]) {
      const arm = new THREE.Mesh(new THREE.BoxGeometry(0.3, 0.9, 0.3), body);
      arm.position.set(s * 0.68, 0.55, 0);
      const fist = new THREE.Mesh(new THREE.IcosahedronGeometry(0.3, 0), accent);
      fist.position.set(s * 0.68, 0.05, 0);
      torso.add(arm, fist);
    }
    torso.position.y = 0.2;
    height = 2.4;
  } else {
    // warden: tall, robed, with a floating energy ring — silhouette first.
    const robe = new THREE.Mesh(new THREE.CylinderGeometry(0.42, 0.95, 1.5, 6), body);
    robe.position.y = 0.75;
    torso.add(robe);
    const shoulders = new THREE.Mesh(new THREE.BoxGeometry(1.25, 0.24, 0.55), accent);
    shoulders.position.y = 1.45;
    torso.add(shoulders);
    const headMesh = new THREE.Mesh(new THREE.OctahedronGeometry(0.36, 0), accent);
    headMesh.position.y = 1.82;
    head.add(headMesh);
    torso.add(head);
    const ring = new THREE.Mesh(new THREE.TorusGeometry(0.75, 0.07, 4, 10), accent);
    ring.rotation.x = Math.PI / 2;
    ring.position.y = 2.15;
    ring.name = 'halo';
    torso.add(ring);
    for (const s of [-1, 1]) {
      const arm = new THREE.Mesh(new THREE.BoxGeometry(0.2, 1.0, 0.2), body);
      arm.position.set(s * 0.66, 1.0, 0);
      torso.add(arm);
    }
    height = 3.0;
  }

  root.add(torso);
  root.scale.setScalar(visual.scale);
  root.traverse((o) => {
    if ((o as THREE.Mesh).isMesh) o.castShadow = true;
  });

  const stub = () => new THREE.Group();
  return {
    root,
    torso,
    head,
    armL: stub(),
    armR: stub(),
    legL: stub(),
    legR: stub(),
    weapon: null,
    height: height * visual.scale,
  };
}

/** Box with a narrower top face — cheap way to get a non-boxy silhouette. */
function taperedBox(
  w: number,
  h: number,
  d: number,
  topScale: number,
): THREE.BufferGeometry {
  const g = new THREE.BoxGeometry(w, h, d);
  const pos = g.attributes.position;
  for (let i = 0; i < pos.count; i++) {
    if (pos.getY(i) > 0) {
      pos.setX(i, pos.getX(i) * topScale);
      pos.setZ(i, pos.getZ(i) * topScale);
    }
  }
  g.computeVertexNormals();
  return g;
}
