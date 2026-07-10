import * as THREE from 'three';
import { toon } from './toon.js';

// Deterministischer Zufall, damit die Welt bei jedem Start gleich aussieht
function mulberry32(a) {
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shadows(obj) {
  obj.traverse((o) => {
    if (o.isMesh) {
      o.castShadow = true;
      o.receiveShadow = true;
    }
  });
  return obj;
}

function makeSakura(rng) {
  const tree = new THREE.Group();
  const trunk = new THREE.Mesh(new THREE.CylinderGeometry(0.22, 0.32, 2.6, 6), toon(0x6b4a35));
  trunk.position.y = 1.3;
  tree.add(trunk);

  const colors = [0xffb7d5, 0xff9ec9, 0xffc9e0];
  for (let i = 0; i < 3; i++) {
    const puff = new THREE.Mesh(
      new THREE.IcosahedronGeometry(1.1 + rng() * 0.5, 0),
      toon(colors[i % colors.length])
    );
    puff.position.set((rng() - 0.5) * 1.4, 2.9 + rng() * 0.9, (rng() - 0.5) * 1.4);
    tree.add(puff);
  }
  return shadows(tree);
}

function makeTree(rng) {
  const tree = new THREE.Group();
  const trunk = new THREE.Mesh(new THREE.CylinderGeometry(0.2, 0.3, 2.2, 6), toon(0x7a5230));
  trunk.position.y = 1.1;
  tree.add(trunk);

  const leafColor = rng() > 0.5 ? 0x58c25c : 0x3fae52;
  for (let i = 0; i < 2; i++) {
    const cone = new THREE.Mesh(new THREE.ConeGeometry(1.5 - i * 0.5, 2.0, 7), toon(leafColor));
    cone.position.y = 2.6 + i * 1.1;
    tree.add(cone);
  }
  return shadows(tree);
}

function makeRock(rng) {
  const s = 0.5 + rng() * 1.0;
  const rock = new THREE.Mesh(new THREE.DodecahedronGeometry(s, 0), toon(0x9aa3ad));
  rock.position.y = s * 0.55;
  rock.rotation.set(rng() * Math.PI, rng() * Math.PI, rng() * Math.PI);
  rock.userData.radius = s;
  return shadows(rock);
}

function makeFlower(rng) {
  const g = new THREE.Group();
  const stem = new THREE.Mesh(new THREE.CylinderGeometry(0.03, 0.03, 0.35, 4), toon(0x3fae52));
  stem.position.y = 0.18;
  const colors = [0xffe066, 0xff6b81, 0x74c0fc, 0xffffff, 0xffa94d];
  const head = new THREE.Mesh(
    new THREE.SphereGeometry(0.12, 6, 5),
    toon(colors[Math.floor(rng() * colors.length)])
  );
  head.position.y = 0.4;
  g.add(stem, head);
  return g;
}

function makeTorii() {
  const g = new THREE.Group();
  const red = toon(0xd94f3d);

  for (const x of [-3, 3]) {
    const pillar = new THREE.Mesh(new THREE.CylinderGeometry(0.32, 0.38, 5.6, 8), red);
    pillar.position.set(x, 2.8, 0);
    g.add(pillar);
  }
  const top = new THREE.Mesh(new THREE.BoxGeometry(8.6, 0.55, 0.8), red);
  top.position.y = 5.7;
  const top2 = new THREE.Mesh(new THREE.BoxGeometry(9.4, 0.3, 0.6), toon(0x8c2f25));
  top2.position.y = 6.15;
  const mid = new THREE.Mesh(new THREE.BoxGeometry(7.0, 0.4, 0.5), red);
  mid.position.y = 4.5;
  g.add(top, top2, mid);
  return shadows(g);
}

function makeCloud(rng) {
  const g = new THREE.Group();
  const mat = new THREE.MeshBasicMaterial({ color: 0xffffff });
  const n = 2 + Math.floor(rng() * 2);
  for (let i = 0; i < n; i++) {
    const puff = new THREE.Mesh(new THREE.IcosahedronGeometry(2.2 + rng() * 1.6, 0), mat);
    puff.position.set(i * 2.6, (rng() - 0.5) * 0.8, (rng() - 0.5) * 1.5);
    puff.scale.y = 0.55;
    g.add(puff);
  }
  return g;
}

export function createWorld(scene) {
  const rng = mulberry32(42);
  const obstacles = []; // { x, z, radius } für simple Kreis-Kollision
  const bounds = 58; // Weltgrenze (Radius)

  // Boden
  const ground = new THREE.Mesh(new THREE.CircleGeometry(bounds + 12, 48), toon(0x7ccf5f));
  ground.rotation.x = -Math.PI / 2;
  ground.receiveShadow = true;
  scene.add(ground);

  // Torii-Tor beim Spawn
  const torii = makeTorii();
  torii.position.set(0, 0, -12);
  scene.add(torii);
  obstacles.push({ x: -3, z: -12, radius: 0.7 }, { x: 3, z: -12, radius: 0.7 });

  // Bäume (Sakura + normale)
  for (let i = 0; i < 34; i++) {
    const angle = rng() * Math.PI * 2;
    const dist = 10 + rng() * (bounds - 12);
    const x = Math.cos(angle) * dist;
    const z = Math.sin(angle) * dist;
    const tree = rng() > 0.45 ? makeSakura(rng) : makeTree(rng);
    tree.position.set(x, 0, z);
    tree.rotation.y = rng() * Math.PI * 2;
    scene.add(tree);
    obstacles.push({ x, z, radius: 0.75 });
  }

  // Felsen
  for (let i = 0; i < 12; i++) {
    const angle = rng() * Math.PI * 2;
    const dist = 7 + rng() * (bounds - 9);
    const rock = makeRock(rng);
    rock.position.x = Math.cos(angle) * dist;
    rock.position.z = Math.sin(angle) * dist;
    scene.add(rock);
    obstacles.push({ x: rock.position.x, z: rock.position.z, radius: rock.userData.radius });
  }

  // Blumen (keine Kollision)
  for (let i = 0; i < 60; i++) {
    const angle = rng() * Math.PI * 2;
    const dist = 3 + rng() * (bounds - 4);
    const flower = makeFlower(rng);
    flower.position.set(Math.cos(angle) * dist, 0, Math.sin(angle) * dist);
    scene.add(flower);
  }

  // Wolken
  const clouds = [];
  for (let i = 0; i < 7; i++) {
    const cloud = makeCloud(rng);
    cloud.position.set((rng() - 0.5) * 160, 24 + rng() * 10, (rng() - 0.5) * 160);
    scene.add(cloud);
    clouds.push(cloud);
  }

  return {
    obstacles,
    bounds,
    update(dt) {
      for (const cloud of clouds) {
        cloud.position.x += dt * 1.2;
        if (cloud.position.x > 100) cloud.position.x = -100;
      }
    },
  };
}
