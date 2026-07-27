import * as THREE from 'three';
import type { WorldPalette, ZoneDef } from '@/shared/types';
import type { Terrain } from '@/sim/terrain';
import { RNG, hashSeed } from '@/sim/rng';
import { MaterialFactory, setFlatShading } from '../materials/toon';
import { makePropGeometry } from './props';

/**
 * Builds the visible zone: terrain, water plane, instanced props, lighting.
 * Everything repeated goes through InstancedMesh — a zone with 2,000 rocks is
 * one draw call instanced and 2,000 draw calls otherwise.
 */
export class ZoneScene {
  readonly group = new THREE.Group();
  private disposables: (THREE.BufferGeometry | THREE.Material | THREE.Texture)[] = [];
  private instanced: THREE.InstancedMesh[] = [];

  constructor(
    private zone: ZoneDef,
    private terrain: Terrain,
    private palette: WorldPalette,
    private materials: MaterialFactory,
    quality: { foliageFraction: number },
  ) {
    this.buildTerrain();
    this.buildWater();
    this.buildProps(quality.foliageFraction);
    this.buildChests();
  }

  // ------------------------------------------------------------- terrain

  private buildTerrain() {
    const { size, segments } = this.zone.terrain;
    const geo = new THREE.PlaneGeometry(size, size, segments, segments);
    geo.rotateX(-Math.PI / 2);

    const pos = geo.attributes.position;
    const colors = new Float32Array(pos.count * 3);
    const low = new THREE.Color(this.palette.terrainLow);
    const high = new THREE.Color(this.palette.terrainHigh);
    const tmp = new THREE.Color();

    for (let i = 0; i < pos.count; i++) {
      const x = pos.getX(i);
      const z = pos.getZ(i);
      const h = this.terrain.heightAt(x, z);
      pos.setY(i, h);

      // Vertex colour by height instead of a texture: no sampler, no atlas,
      // and it keeps the whole terrain on one material.
      const t = THREE.MathUtils.clamp(
        (h - this.terrain.waterLevel) / (this.zone.terrain.heightScale * 1.1),
        0,
        1,
      );
      tmp.copy(low).lerp(high, Math.pow(t, 1.4));
      colors[i * 3] = tmp.r;
      colors[i * 3 + 1] = tmp.g;
      colors[i * 3 + 2] = tmp.b;
    }

    geo.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    // Non-indexed + computed normals is what produces the hard facets.
    const faceted = geo.toNonIndexed();
    faceted.computeVertexNormals();
    geo.dispose();

    const mat = new THREE.MeshToonMaterial({
      vertexColors: true,
      gradientMap: this.materials.ramp,
    });
    setFlatShading(mat);

    const mesh = new THREE.Mesh(faceted, mat);
    mesh.receiveShadow = true;
    mesh.name = 'terrain';
    this.group.add(mesh);
    this.disposables.push(faceted, mat);
  }

  private buildWater() {
    const geo = new THREE.PlaneGeometry(this.zone.terrain.size * 1.2, this.zone.terrain.size * 1.2);
    geo.rotateX(-Math.PI / 2);
    const mat = new THREE.MeshToonMaterial({
      color: this.palette.water,
      gradientMap: this.materials.ramp,
      transparent: true,
      opacity: 0.78,
    });
    const mesh = new THREE.Mesh(geo, mat);
    mesh.position.y = this.zone.terrain.waterLevel;
    mesh.name = 'water';
    this.group.add(mesh);
    this.disposables.push(geo, mat);
  }

  // ------------------------------------------------------------- props

  private buildProps(foliageFraction: number) {
    const rng = new RNG(hashSeed(this.zone.id, 'props'));
    const dummy = new THREE.Object3D();

    for (const spec of this.zone.props) {
      const isFoliage = spec.archetype === 'frond';
      const count = Math.max(1, Math.floor(spec.count * (isFoliage ? foliageFraction : 1)));
      const geo = makePropGeometry(spec.archetype);
      const mat = this.materials.toon(
        PROP_COLORS[spec.archetype] ?? 0x888888,
        spec.archetype === 'crystal' ? 0.6 : 0,
      );

      const mesh = new THREE.InstancedMesh(geo, mat, count);
      mesh.castShadow = spec.archetype === 'spire';
      mesh.receiveShadow = false;
      mesh.frustumCulled = false; // One bounding volume spans the zone anyway.

      let placed = 0;
      let guard = 0;
      while (placed < count && guard++ < count * 40) {
        const angle = rng.next() * Math.PI * 2;
        const r = Math.sqrt(rng.next()) * this.zone.terrain.size * 0.44;
        const x = Math.cos(angle) * r;
        const z = Math.sin(angle) * r;

        // Keep props out of the water and off the spawn pad.
        if (this.terrain.isWater(x, z)) continue;
        if (Math.hypot(x, z) < 7) continue;
        if (spec.archetype === 'spire' && this.terrain.slopeAt(x, z) > 1.0) continue;

        const s = rng.range(spec.scaleRange[0], spec.scaleRange[1]);
        dummy.position.set(x, this.terrain.heightAt(x, z) - 0.1, z);
        dummy.rotation.set(0, rng.next() * Math.PI * 2, 0);
        dummy.scale.setScalar(s);
        dummy.updateMatrix();
        mesh.setMatrixAt(placed, dummy.matrix);
        placed++;
      }
      mesh.count = placed;
      mesh.instanceMatrix.needsUpdate = true;

      this.group.add(mesh);
      this.instanced.push(mesh);
      this.disposables.push(geo);
    }
  }

  private buildChests() {
    const geo = new THREE.BoxGeometry(0.9, 0.7, 0.7);
    const lid = new THREE.BoxGeometry(0.95, 0.25, 0.75);
    const mat = this.materials.toon(0xc98a4b);
    const trim = this.materials.toon(0xffe08a, 0.4);

    for (const c of this.zone.chests) {
      const g = new THREE.Group();
      const body = new THREE.Mesh(geo, mat);
      body.castShadow = true;
      const top = new THREE.Mesh(lid, trim);
      top.position.y = 0.45;
      g.add(body, top);
      g.position.set(c.at[0], this.terrain.heightAt(c.at[0], c.at[2]) + 0.35, c.at[2]);
      g.name = `chest:${c.id}`;
      this.group.add(g);
    }
    this.disposables.push(geo, lid);
  }

  /** Called when a chest is looted so the world reflects sim state. */
  markChestOpened(chestId: string) {
    const g = this.group.getObjectByName(`chest:${chestId}`);
    if (!g) return;
    const lid = g.children[1];
    if (lid) {
      lid.rotation.x = -1.1;
      lid.position.set(0, 0.55, -0.35);
    }
  }

  dispose() {
    for (const m of this.instanced) m.dispose();
    for (const d of this.disposables) d.dispose();
    this.disposables.length = 0;
    this.instanced.length = 0;
    this.group.clear();
  }
}

const PROP_COLORS: Record<string, number> = {
  spire: 0xc98a4b,
  rock: 0x7a6250,
  crystal: 0x6effc9,
  frond: 0x5fbf72,
};

/** Lighting rig. Three lights only — more means more shader permutations. */
export function buildLighting(palette: WorldPalette): {
  group: THREE.Group;
  key: THREE.DirectionalLight;
} {
  const group = new THREE.Group();

  const hemi = new THREE.HemisphereLight(
    palette.hemisphere.sky,
    palette.hemisphere.ground,
    palette.hemisphere.intensity,
  );
  group.add(hemi);

  const ambient = new THREE.AmbientLight(palette.ambient, palette.ambientIntensity);
  group.add(ambient);

  const key = new THREE.DirectionalLight(palette.keyLight.color, palette.keyLight.intensity);
  const el = THREE.MathUtils.degToRad(palette.keyLight.elevation);
  const az = THREE.MathUtils.degToRad(palette.keyLight.azimuth);
  key.position.set(
    Math.cos(el) * Math.sin(az) * 60,
    Math.sin(el) * 60,
    Math.cos(el) * Math.cos(az) * 60,
  );
  key.castShadow = true;
  key.shadow.mapSize.set(1024, 1024);
  // Tightly fitted ortho box around the player keeps 1024x1024 sharp.
  const d = 40;
  key.shadow.camera.left = -d;
  key.shadow.camera.right = d;
  key.shadow.camera.top = d;
  key.shadow.camera.bottom = -d;
  key.shadow.camera.near = 1;
  key.shadow.camera.far = 200;
  key.shadow.bias = -0.0015;
  group.add(key, key.target);

  return { group, key };
}
