import * as THREE from 'three';

/**
 * Procedural low-poly prop geometry, standing in for authored GLBs. Every
 * archetype is a handful of triangles so the whole zone stays well inside the
 * 250k-triangle frame budget even at 2,000 instances.
 */
export function makePropGeometry(archetype: string): THREE.BufferGeometry {
  switch (archetype) {
    case 'spire': {
      // Tapered, slightly twisted column — reads as an alien rock needle.
      const g = new THREE.CylinderGeometry(0.28, 1.0, 4.0, 5, 2);
      const pos = g.attributes.position;
      for (let i = 0; i < pos.count; i++) {
        const y = pos.getY(i);
        const twist = y * 0.16;
        const x = pos.getX(i);
        const z = pos.getZ(i);
        pos.setX(i, x * Math.cos(twist) - z * Math.sin(twist));
        pos.setZ(i, x * Math.sin(twist) + z * Math.cos(twist));
      }
      g.translate(0, 2.0, 0);
      g.computeVertexNormals();
      return g;
    }
    case 'rock': {
      const g = new THREE.IcosahedronGeometry(0.7, 0);
      jitter(g, 0.22, 91);
      g.scale(1, 0.75, 1);
      g.translate(0, 0.35, 0);
      g.computeVertexNormals();
      return g;
    }
    case 'crystal': {
      const g = new THREE.OctahedronGeometry(0.5, 0);
      g.scale(0.6, 1.9, 0.6);
      g.translate(0, 0.9, 0);
      g.computeVertexNormals();
      return g;
    }
    case 'frond': {
      // A splayed cluster of tapered blades. Crossed camera-facing quads are
      // the usual trick, but untextured and unlit they read as floating
      // rectangles — solid geometry costs a few more triangles and actually
      // catches the light.
      const geos: THREE.BufferGeometry[] = [];
      const blades = 5;
      for (let i = 0; i < blades; i++) {
        const b = new THREE.ConeGeometry(0.13, 1.25, 3);
        b.translate(0, 0.62, 0);
        // Splay outward from the base and fan around the vertical axis.
        b.rotateZ(0.42);
        b.rotateY((i / blades) * Math.PI * 2);
        geos.push(b);
      }
      const centre = new THREE.ConeGeometry(0.12, 1.5, 3);
      centre.translate(0, 0.75, 0);
      geos.push(centre);
      const merged = mergeGeometries(geos);
      merged.computeVertexNormals();
      return merged;
    }
    default:
      return new THREE.BoxGeometry(1, 1, 1);
  }
}

function jitter(g: THREE.BufferGeometry, amount: number, seed: number) {
  const pos = g.attributes.position;
  let s = seed;
  const rand = () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296 - 0.5;
  };
  for (let i = 0; i < pos.count; i++) {
    pos.setXYZ(
      i,
      pos.getX(i) + rand() * amount,
      pos.getY(i) + rand() * amount,
      pos.getZ(i) + rand() * amount,
    );
  }
  pos.needsUpdate = true;
}

/** Minimal geometry merge — avoids pulling in the BufferGeometryUtils addon. */
export function mergeGeometries(geos: THREE.BufferGeometry[]): THREE.BufferGeometry {
  const out = new THREE.BufferGeometry();
  const positions: number[] = [];
  const normals: number[] = [];

  for (const g of geos) {
    const nonIndexed = g.index ? g.toNonIndexed() : g;
    const p = nonIndexed.attributes.position;
    if (!nonIndexed.attributes.normal) nonIndexed.computeVertexNormals();
    const n = nonIndexed.attributes.normal;
    for (let i = 0; i < p.count; i++) {
      positions.push(p.getX(i), p.getY(i), p.getZ(i));
      normals.push(n.getX(i), n.getY(i), n.getZ(i));
    }
    if (nonIndexed !== g) nonIndexed.dispose();
    g.dispose();
  }

  out.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  out.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3));
  return out;
}
