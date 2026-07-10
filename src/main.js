import * as THREE from 'three';
import './style.css';
import { createWorld } from './world.js';
import { Player } from './player.js';
import { CameraRig } from './cameraRig.js';
import { Input } from './input.js';
import { EnemyManager } from './enemy.js';
import { Effects } from './effects.js';
import { UI } from './ui.js';

// Renderer
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
document.querySelector('#app').appendChild(renderer.domElement);

// Szene + Himmel
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x7ec8ff);
scene.fog = new THREE.Fog(0x9ad4ff, 55, 150);

// Kamera
const camera = new THREE.PerspectiveCamera(
  60,
  window.innerWidth / window.innerHeight,
  0.1,
  500
);
camera.position.set(0, 4, 8);

// Licht
const hemi = new THREE.HemisphereLight(0xbfe3ff, 0x88cc66, 0.9);
scene.add(hemi);

const sun = new THREE.DirectionalLight(0xfff2cc, 1.3);
sun.position.set(30, 50, 20);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
sun.shadow.camera.left = -70;
sun.shadow.camera.right = 70;
sun.shadow.camera.top = 70;
sun.shadow.camera.bottom = -70;
sun.shadow.camera.far = 150;
scene.add(sun);

// Welt, Spieler, Steuerung, Gegner, UI
const world = createWorld(scene);
const player = new Player(scene);
const input = new Input();
const rig = new CameraRig(camera, renderer.domElement);
const ui = new UI();
const effects = new Effects(scene);

const enemies = new EnemyManager(scene, world, {
  ui,
  effects,
  camera,
  onKill: (enemy) => player.gainXp(enemy.xp),
});

// Klick ohne Ziehen = Angriff
rig.onTap = () => input.queueAttack();

// Spieler-Ereignisse -> HUD & Effekte
player.onStatsChanged = () => {
  ui.setHp(player.hp, player.maxHp);
  ui.setXp(player.xp, player.xpNext);
  ui.setLevel(player.level);
};
player.onDamaged = (dmg) => {
  ui.flashVignette();
  rig.addShake(0.35);
  const pos = player.group.position.clone();
  pos.y = 2.4;
  ui.damageNumber(pos, camera, `-${dmg}`, 'dmg-hurt');
};
player.onDeath = () => ui.announce('K.O.!', 'announce-ko');
player.onLevelUp = () => {
  ui.announce('LEVEL UP!', 'announce-level');
  effects.levelUpRing(player.group.position);
};
player.onStatsChanged();

// Debug-Zugriff (Konsole/Tests)
window.__game = { player, enemies, rig, world };

// Game-Loop
const clock = new THREE.Clock();
function tick() {
  const dt = Math.min(clock.getDelta(), 0.05);

  if (input.consumeAttack()) player.tryAttack();
  player.update(dt, input, rig.yaw, world);
  if (player.didStrike) enemies.playerStrike(player);
  enemies.update(dt, player);
  effects.update(dt);
  rig.update(dt, player.group.position);
  world.update(dt);

  renderer.render(scene, camera);
  requestAnimationFrame(tick);
}
tick();

// Fenstergröße
window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});
