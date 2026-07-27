import * as THREE from 'three';
import type { WorldPalette } from '@/shared/types';

/** See MaterialFactory.toon for why this needs a cast. */
export function setFlatShading(mat: THREE.Material): void {
  (mat as THREE.Material & { flatShading: boolean }).flatShading = true;
}

/**
 * A 1xN ramp with NearestFilter. That hard step is the entire cel look, and
 * it costs one tiny texture shared by every material in the world.
 */
export function makeRampTexture(stops: string[]): THREE.DataTexture {
  const data = new Uint8Array(stops.length * 4);
  stops.forEach((hex, i) => {
    const c = new THREE.Color(hex);
    data[i * 4 + 0] = Math.round(c.r * 255);
    data[i * 4 + 1] = Math.round(c.g * 255);
    data[i * 4 + 2] = Math.round(c.b * 255);
    data[i * 4 + 3] = 255;
  });
  const tex = new THREE.DataTexture(data, stops.length, 1, THREE.RGBAFormat);
  tex.magFilter = THREE.NearestFilter;
  tex.minFilter = THREE.NearestFilter;
  tex.generateMipmaps = false;
  tex.needsUpdate = true;
  return tex;
}

/**
 * One material factory for the whole game. Materials are cached per
 * (colour, emissive) pair so a zone with 2,000 props still shares a handful
 * of programs and can be batched.
 */
export class MaterialFactory {
  readonly ramp: THREE.DataTexture;
  private cache = new Map<string, THREE.MeshToonMaterial>();
  private owned: THREE.Material[] = [];

  constructor(palette: WorldPalette) {
    this.ramp = makeRampTexture(palette.rampStops);
  }

  toon(color: THREE.ColorRepresentation, emissiveIntensity = 0): THREE.MeshToonMaterial {
    const key = `${new THREE.Color(color).getHexString()}:${emissiveIntensity}`;
    const hit = this.cache.get(key);
    if (hit) return hit;

    const mat = new THREE.MeshToonMaterial({ color, gradientMap: this.ramp });
    // Faceting is the style; smooth normals read as unfinished rather than
    // deliberately low-poly. MeshToonMaterial omits flatShading from its
    // typed surface, but WebGLProgram reads material.flatShading for every
    // material type, so setting it here does produce the FLAT_SHADED define.
    setFlatShading(mat);
    if (emissiveIntensity > 0) {
      mat.emissive = new THREE.Color(color);
      mat.emissiveIntensity = emissiveIntensity;
    }
    this.cache.set(key, mat);
    this.owned.push(mat);
    return mat;
  }

  /** Backface-culled hull for the anime outline. One extra draw call. */
  outline(thickness = 0.03): THREE.ShaderMaterial {
    const mat = new THREE.ShaderMaterial({
      side: THREE.BackSide,
      uniforms: { uThickness: { value: thickness } },
      vertexShader: /* glsl */ `
        uniform float uThickness;
        void main() {
          vec3 inflated = position + normal * uThickness;
          gl_Position = projectionMatrix * modelViewMatrix * vec4(inflated, 1.0);
        }
      `,
      fragmentShader: /* glsl */ `
        void main() { gl_FragColor = vec4(0.03, 0.06, 0.05, 1.0); }
      `,
    });
    this.owned.push(mat);
    return mat;
  }

  dispose() {
    this.ramp.dispose();
    for (const m of this.owned) m.dispose();
    this.owned.length = 0;
    this.cache.clear();
  }
}
