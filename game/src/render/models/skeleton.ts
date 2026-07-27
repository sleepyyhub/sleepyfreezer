import * as THREE from 'three';

/**
 * A joint hierarchy. Each joint is an empty Group at an anatomically correct
 * pivot; geometry hangs off it as a child. Animation only ever writes joint
 * transforms, never mesh transforms — that separation is what lets one clip
 * drive any rig that declares the same joint names.
 *
 * This is deliberately rigid-segment rather than skinned: at low-poly facet
 * density, skinning buys smooth deformation nobody can see while costing bone
 * weights, a skinned-material path, and per-vertex CPU work. Segmented limbs
 * with correct pivots are what the look actually calls for.
 */
export class Joint extends THREE.Group {
  readonly jointName: string;
  /** Rest transform. Poses are applied as deltas from this. */
  readonly bindPosition = new THREE.Vector3();
  readonly bindRotation = new THREE.Euler();

  constructor(name: string, position: [number, number, number] = [0, 0, 0]) {
    super();
    this.jointName = name;
    this.name = `joint:${name}`;
    this.position.set(...position);
    this.bindPosition.copy(this.position);
    this.bindRotation.copy(this.rotation);
  }

  /** Re-reads the current transform as the new rest pose. */
  rebind(): this {
    this.bindPosition.copy(this.position);
    this.bindRotation.copy(this.rotation);
    return this;
  }
}

export interface Rig {
  root: THREE.Group;
  joints: Map<string, Joint>;
  /** Total height in metres — used for health-bar placement and camera framing. */
  height: number;
  /** Approximate ground-to-hip distance, used by foot-planting logic. */
  hipHeight: number;
  /** Which clip family this rig understands. */
  family: 'humanoid' | 'insect' | 'golem' | 'warden';
  triangles: number;
}

export class RigBuilder {
  readonly root = new THREE.Group();
  readonly joints = new Map<string, Joint>();
  private triangles = 0;

  /** Creates a joint and parents it to `parent` (or the rig root). */
  joint(name: string, position: [number, number, number], parent?: string): Joint {
    if (this.joints.has(name)) throw new Error(`Duplicate joint: ${name}`);
    const j = new Joint(name, position);
    const p = parent ? this.joints.get(parent) : undefined;
    if (parent && !p) throw new Error(`Unknown parent joint: ${parent}`);
    (p ?? this.root).add(j);
    this.joints.set(name, j);
    return j;
  }

  /** Attaches geometry to a joint. */
  attach(
    jointName: string,
    geo: THREE.BufferGeometry,
    material: THREE.Material,
    transform?: {
      position?: [number, number, number];
      rotation?: [number, number, number];
      scale?: [number, number, number] | number;
    },
  ): THREE.Mesh {
    const j = this.joints.get(jointName);
    if (!j) throw new Error(`Unknown joint: ${jointName}`);

    const mesh = new THREE.Mesh(geo, material);
    if (transform?.position) mesh.position.set(...transform.position);
    if (transform?.rotation) mesh.rotation.set(...transform.rotation);
    if (transform?.scale !== undefined) {
      if (typeof transform.scale === 'number') mesh.scale.setScalar(transform.scale);
      else mesh.scale.set(...transform.scale);
    }
    mesh.castShadow = true;
    mesh.receiveShadow = false;
    j.add(mesh);

    this.triangles += geo.attributes.position.count / 3;
    return mesh;
  }

  /**
   * Mirrors an existing joint subtree onto the opposite side. Building the
   * left arm once and mirroring guarantees the two sides stay symmetric as
   * the model is tweaked.
   */
  build(family: Rig['family'], height: number, hipHeight: number): Rig {
    for (const j of this.joints.values()) j.rebind();
    return {
      root: this.root,
      joints: this.joints,
      height,
      hipHeight,
      family,
      triangles: Math.round(this.triangles),
    };
  }
}

/** Frees every geometry hanging off a rig. Materials are shared and cached. */
export function disposeRig(rig: Rig) {
  rig.root.traverse((o) => {
    const m = o as THREE.Mesh;
    if (m.isMesh && m.geometry) m.geometry.dispose();
  });
  rig.root.removeFromParent();
}

// ------------------------------------------------------------------ names

/**
 * Canonical joint names. Clips are written against these strings, so a rig
 * that declares them gets every humanoid clip for free.
 */
export const HUMANOID_JOINTS = [
  'root',
  'hips',
  'spine',
  'chest',
  'neck',
  'head',
  'hair',
  'shoulderL',
  'armL',
  'forearmL',
  'handL',
  'shoulderR',
  'armR',
  'forearmR',
  'handR',
  'thighL',
  'shinL',
  'footL',
  'thighR',
  'shinR',
  'footR',
] as const;

export type HumanoidJoint = (typeof HUMANOID_JOINTS)[number];

/** Joints an upper-body action clip may override while the legs keep walking. */
export const UPPER_BODY_MASK: string[] = [
  'spine',
  'chest',
  'neck',
  'head',
  'shoulderL',
  'armL',
  'forearmL',
  'handL',
  'shoulderR',
  'armR',
  'forearmR',
  'handR',
];
