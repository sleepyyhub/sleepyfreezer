import * as THREE from 'three';

/**
 * Low-poly geometry primitives with actual anatomy. The core idea is the
 * *profile mesh*: a lofted tube whose cross-section radius varies ring by
 * ring, so an upper arm can bulge at the deltoid and taper at the elbow
 * instead of being a box. Cross-sections are elliptical (rx != rz) because
 * limbs are wider than they are deep — that single detail is most of what
 * separates a limb from a cylinder.
 *
 * Everything here returns non-indexed geometry with face normals, which is
 * what produces the hard facets the art direction depends on.
 */

export interface Ring {
  /** Distance along the limb axis. Limbs are built along -Y from the joint. */
  y: number;
  /** Half-width (left/right). */
  rx: number;
  /** Half-depth (front/back). */
  rz: number;
  /** Lateral offset of this ring's centre — gives a limb its curve. */
  ox?: number;
  /** Fore/aft offset — calf bulge, chest depth, heel. */
  oz?: number;
  /** Rotates the cross-section about the limb axis (forearm pronation). */
  twist?: number;
}

/**
 * Lofts a closed tube through the given rings.
 *
 * @param sides Cross-section vertex count. 5-7 reads as low-poly organic;
 *              4 reads as a box, 12+ stops being low-poly.
 */
export function profileMesh(rings: Ring[], sides = 6, capEnds = true): THREE.BufferGeometry {
  if (rings.length < 2) throw new Error('profileMesh needs at least two rings');

  const positions: number[] = [];
  const indices: number[] = [];

  const ringVerts: number[][] = rings.map((ring) => {
    const base = positions.length / 3;
    const idx: number[] = [];
    for (let s = 0; s < sides; s++) {
      const a = (s / sides) * Math.PI * 2 + (ring.twist ?? 0);
      positions.push(
        (ring.ox ?? 0) + Math.cos(a) * ring.rx,
        ring.y,
        (ring.oz ?? 0) + Math.sin(a) * ring.rz,
      );
      idx.push(base + s);
    }
    return idx;
  });

  for (let r = 0; r < rings.length - 1; r++) {
    const a = ringVerts[r];
    const b = ringVerts[r + 1];
    for (let s = 0; s < sides; s++) {
      const n = (s + 1) % sides;
      indices.push(a[s], b[s], b[n]);
      indices.push(a[s], b[n], a[n]);
    }
  }

  if (capEnds) {
    // Fan caps from a centre vertex, so the end reads as a solid face rather
    // than an open pipe when seen from the side.
    const capFan = (ringIdx: number, flip: boolean) => {
      const ring = rings[ringIdx];
      const centre = positions.length / 3;
      positions.push(ring.ox ?? 0, ring.y, ring.oz ?? 0);
      const verts = ringVerts[ringIdx];
      for (let s = 0; s < sides; s++) {
        const n = (s + 1) % sides;
        if (flip) indices.push(centre, verts[n], verts[s]);
        else indices.push(centre, verts[s], verts[n]);
      }
    };
    capFan(0, true);
    capFan(rings.length - 1, false);
  }

  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geo.setIndex(indices);
  return faceted(geo);
}

/** Splits shared vertices and recomputes normals to get hard facets. */
export function faceted(geo: THREE.BufferGeometry): THREE.BufferGeometry {
  const out = geo.index ? geo.toNonIndexed() : geo;
  if (out !== geo) geo.dispose();
  out.computeVertexNormals();
  return out;
}

/**
 * A box whose eight corners can each be scaled — the workhorse for hands,
 * feet, jaws and armour plates, where a plain box reads as programmer art but
 * a slightly tapered, bevelled one reads as sculpted.
 */
export function shapedBox(
  w: number,
  h: number,
  d: number,
  opts: {
    topScale?: number | [number, number];
    bottomScale?: number | [number, number];
    frontScale?: number;
    backScale?: number;
    shearZ?: number;
  } = {},
): THREE.BufferGeometry {
  const geo = new THREE.BoxGeometry(w, h, d);
  const pos = geo.attributes.position;
  const pair = (v: number | [number, number] | undefined): [number, number] =>
    v === undefined ? [1, 1] : typeof v === 'number' ? [v, v] : v;

  const [tx, tz] = pair(opts.topScale);
  const [bx, bz] = pair(opts.bottomScale);

  for (let i = 0; i < pos.count; i++) {
    const x = pos.getX(i);
    const y = pos.getY(i);
    let z = pos.getZ(i);

    const sx = y > 0 ? tx : bx;
    const sz = y > 0 ? tz : bz;
    let nx = x * sx;
    z *= sz;

    if (z > 0 && opts.frontScale !== undefined) nx *= opts.frontScale;
    if (z < 0 && opts.backScale !== undefined) nx *= opts.backScale;
    if (opts.shearZ) z += y * opts.shearZ;

    pos.setXYZ(i, nx, y, z);
  }
  return faceted(geo);
}

/** Merges geometries, baking each one's transform. */
export function mergeAll(
  parts: { geo: THREE.BufferGeometry; matrix?: THREE.Matrix4 }[],
): THREE.BufferGeometry {
  const positions: number[] = [];
  const normals: number[] = [];
  const normalMat = new THREE.Matrix3();

  for (const part of parts) {
    const g = part.geo.index ? part.geo.toNonIndexed() : part.geo;
    if (!g.attributes.normal) g.computeVertexNormals();
    const p = g.attributes.position;
    const n = g.attributes.normal;
    const v = new THREE.Vector3();
    const nv = new THREE.Vector3();
    if (part.matrix) normalMat.getNormalMatrix(part.matrix);

    for (let i = 0; i < p.count; i++) {
      v.fromBufferAttribute(p, i);
      nv.fromBufferAttribute(n, i);
      if (part.matrix) {
        v.applyMatrix4(part.matrix);
        nv.applyMatrix3(normalMat).normalize();
      }
      positions.push(v.x, v.y, v.z);
      normals.push(nv.x, nv.y, nv.z);
    }
    if (g !== part.geo) g.dispose();
    part.geo.dispose();
  }

  const out = new THREE.BufferGeometry();
  out.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  out.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3));
  return out;
}

/**
 * Builds a matrix that points a +Y-aligned part along `dir`. Composing this
 * from Euler angles is guesswork — the axis order silently changes what the
 * angles mean — whereas aiming at a direction vector is exactly what hair
 * spikes, horns and shards need.
 */
export function orientTo(
  dir: THREE.Vector3,
  position: [number, number, number] = [0, 0, 0],
  scale = 1,
  roll = 0,
): THREE.Matrix4 {
  const q = new THREE.Quaternion().setFromUnitVectors(
    new THREE.Vector3(0, 1, 0),
    dir.clone().normalize(),
  );
  if (roll) q.multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), roll));
  return new THREE.Matrix4().compose(
    new THREE.Vector3(...position),
    q,
    new THREE.Vector3(scale, scale, scale),
  );
}

export function transform(
  pos: [number, number, number] = [0, 0, 0],
  rot: [number, number, number] = [0, 0, 0],
  scale: [number, number, number] | number = 1,
): THREE.Matrix4 {
  const s = typeof scale === 'number' ? [scale, scale, scale] : scale;
  return new THREE.Matrix4().compose(
    new THREE.Vector3(...pos),
    new THREE.Quaternion().setFromEuler(new THREE.Euler(...rot)),
    new THREE.Vector3(s[0], s[1], s[2]),
  );
}

// --------------------------------------------------------------- body parts

/**
 * A hand with individual fingers. At this scale each finger is two short
 * tapered segments; the knuckle line is staggered and the thumb is set lower
 * and rotated inward, which is what stops it reading as a mitten.
 */
export function buildHand(scale = 1, fingerCurl = 0.55): THREE.BufferGeometry {
  const parts: { geo: THREE.BufferGeometry; matrix?: THREE.Matrix4 }[] = [];

  const palm = profileMesh(
    [
      { y: 0, rx: 0.052, rz: 0.032 },
      { y: -0.045, rx: 0.062, rz: 0.036 },
      { y: -0.1, rx: 0.058, rz: 0.03 },
    ],
    6,
  );
  parts.push({ geo: palm });

  // Staggered lengths across the four fingers: index shortest at the outside,
  // middle longest. Even lengths look like a comb.
  const lengths = [0.058, 0.066, 0.062, 0.05];
  for (let i = 0; i < 4; i++) {
    const x = -0.036 + i * 0.024;
    const len = lengths[i];
    const finger = profileMesh(
      [
        { y: 0, rx: 0.012, rz: 0.011 },
        { y: -len * 0.55, rx: 0.0115, rz: 0.0105 },
        { y: -len, rx: 0.0085, rz: 0.008 },
      ],
      4,
    );
    parts.push({
      geo: finger,
      matrix: transform([x, -0.098, 0.004], [fingerCurl + i * 0.05, 0, 0]),
    });
    // Second phalanx, curled further — a single straight finger reads stiff.
    const tip = profileMesh(
      [
        { y: 0, rx: 0.0085, rz: 0.008 },
        { y: -len * 0.6, rx: 0.006, rz: 0.006 },
      ],
      4,
    );
    parts.push({
      geo: tip,
      matrix: transform(
        [x, -0.098 - Math.cos(fingerCurl) * len, 0.004 + Math.sin(fingerCurl) * len],
        [fingerCurl * 2.1 + i * 0.05, 0, 0],
      ),
    });
  }

  const thumb = profileMesh(
    [
      { y: 0, rx: 0.016, rz: 0.014 },
      { y: -0.04, rx: 0.014, rz: 0.012 },
      { y: -0.07, rx: 0.01, rz: 0.009 },
    ],
    4,
  );
  parts.push({ geo: thumb, matrix: transform([-0.052, -0.062, 0.012], [0.5, 0, 0.95]) });

  const geo = mergeAll(parts);
  geo.scale(scale, scale, scale);
  return geo;
}

/** A foot with an arch, a heel that projects backward, and a separate toe box. */
export function buildFoot(scale = 1): THREE.BufferGeometry {
  const parts: { geo: THREE.BufferGeometry; matrix?: THREE.Matrix4 }[] = [];

  const foot = profileMesh(
    [
      { y: 0, rx: 0.055, rz: 0.055, oz: -0.01 },
      { y: -0.05, rx: 0.06, rz: 0.085, oz: 0.015 },
      { y: -0.085, rx: 0.058, rz: 0.1, oz: 0.03 },
    ],
    6,
  );
  parts.push({ geo: foot });

  const toes = shapedBox(0.11, 0.045, 0.075, { topScale: 1.05, frontScale: 0.82 });
  parts.push({ geo: toes, matrix: transform([0, -0.062, 0.125]) });

  // Heel: without it the foot pivots visibly wrong on every step.
  const heel = shapedBox(0.085, 0.06, 0.06, { bottomScale: 0.85 });
  parts.push({ geo: heel, matrix: transform([0, -0.055, -0.055]) });

  const geo = mergeAll(parts);
  geo.scale(scale, scale, scale);
  return geo;
}

/**
 * A humanoid head: tapered cranium, a brow ridge, a jaw that narrows to the
 * chin, and a nose. Anime proportions — large cranium, small jaw, big eyes.
 */
export function buildHead(scale = 1): THREE.BufferGeometry {
  const parts: { geo: THREE.BufferGeometry; matrix?: THREE.Matrix4 }[] = [];

  const cranium = profileMesh(
    [
      { y: 0.135, rx: 0.055, rz: 0.055, oz: -0.005 },
      { y: 0.1, rx: 0.098, rz: 0.099, oz: -0.008 },
      { y: 0.045, rx: 0.113, rz: 0.113, oz: -0.006 },
      { y: 0.0, rx: 0.112, rz: 0.114 },
      { y: -0.045, rx: 0.098, rz: 0.104, oz: 0.004 },
      { y: -0.085, rx: 0.073, rz: 0.086, oz: 0.012 },
      { y: -0.115, rx: 0.045, rz: 0.06, oz: 0.016 },
    ],
    7,
  );
  parts.push({ geo: cranium });

  const brow = shapedBox(0.17, 0.026, 0.05, { frontScale: 0.9 });
  parts.push({ geo: brow, matrix: transform([0, 0.028, 0.086], [0.12, 0, 0]) });

  const nose = profileMesh(
    [
      { y: 0.02, rx: 0.012, rz: 0.012 },
      { y: -0.02, rx: 0.017, rz: 0.02 },
    ],
    4,
  );
  parts.push({ geo: nose, matrix: transform([0, -0.02, 0.105]) });

  const geo = mergeAll(parts);
  geo.scale(scale, scale, scale);
  return geo;
}

/**
 * Torso built as ribcage + waist + pelvis so the spine joint sits at a real
 * anatomical position and twisting reads correctly.
 */
export function buildTorso(
  opts: { shoulderW: number; chestD: number; waistW: number; height: number } = {
    shoulderW: 0.19,
    chestD: 0.11,
    waistW: 0.13,
    height: 0.46,
  },
): THREE.BufferGeometry {
  const h = opts.height;
  return profileMesh(
    [
      { y: h, rx: opts.shoulderW, rz: opts.chestD * 0.85 },
      { y: h * 0.82, rx: opts.shoulderW * 1.02, rz: opts.chestD },
      { y: h * 0.55, rx: opts.shoulderW * 0.9, rz: opts.chestD * 0.95 },
      { y: h * 0.28, rx: opts.waistW * 1.05, rz: opts.chestD * 0.76 },
      { y: 0, rx: opts.waistW, rz: opts.chestD * 0.72 },
    ],
    7,
  );
}

/** Pelvis: wider than the waist, tapering down to the hip sockets. */
export function buildPelvis(w = 0.145, d = 0.095, h = 0.16): THREE.BufferGeometry {
  return profileMesh(
    [
      { y: 0, rx: w * 0.92, rz: d * 0.8 },
      { y: -h * 0.45, rx: w, rz: d },
      { y: -h, rx: w * 0.88, rz: d * 0.86 },
    ],
    7,
  );
}
