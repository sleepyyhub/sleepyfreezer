import * as THREE from 'three';

// Gemeinsame 3-Stufen-Gradient-Map für den Anime-/Cel-Shading-Look
const gradientMap = new THREE.DataTexture(
  new Uint8Array([90, 170, 255]),
  3,
  1,
  THREE.RedFormat
);
gradientMap.minFilter = THREE.NearestFilter;
gradientMap.magFilter = THREE.NearestFilter;
gradientMap.needsUpdate = true;

const cache = new Map();

// Toon-Material mit Cache (gleiche Farbe => gleiches Material)
export function toon(color) {
  if (!cache.has(color)) {
    cache.set(color, new THREE.MeshToonMaterial({ color, gradientMap }));
  }
  return cache.get(color);
}
