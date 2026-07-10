import * as THREE from 'three';
import { toonUnique, toon } from './toon.js';

// Gegner-Stufen
const TIERS = {
  normal: { hp: 30, dmg: 8, speed: 3.6, xp: 15, scale: 1.0, color: 0x7048e8 },
  big: { hp: 70, dmg: 14, speed: 3.0, xp: 40, scale: 1.45, color: 0xc0392b },
};

const AGGRO_RANGE = 11;
const LEASH_RANGE = 24;
const ATTACK_RANGE = 1.8;
const HIT_RANGE = 2.4;

function mulberry32(a) {
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Schwebender Anime-Devil (schaut Richtung +Z)
function buildDevil(tier) {
  const g = new THREE.Group();
  const bodyMat = toonUnique(tier.color); // eigenes Material fürs Aufblitzen
  const dark = toon(0x2a2438);
  const bone = toon(0xf5e9d0);

  const body = new THREE.Mesh(new THREE.BoxGeometry(0.72, 0.8, 0.55), bodyMat);
  body.position.y = 0.85;
  const head = new THREE.Mesh(new THREE.BoxGeometry(0.58, 0.46, 0.5), bodyMat);
  head.position.y = 1.5;
  g.add(body, head);

  // Hörner
  for (const x of [-0.2, 0.2]) {
    const horn = new THREE.Mesh(new THREE.ConeGeometry(0.09, 0.4, 5), bone);
    horn.position.set(x, 1.85, 0);
    horn.rotation.z = -x * 1.4;
    g.add(horn);
  }

  // Glühende, böse Augen
  const eyeMat = new THREE.MeshBasicMaterial({ color: 0xffe066 });
  const eyes = [];
  for (const x of [-0.14, 0.14]) {
    const eye = new THREE.Mesh(new THREE.BoxGeometry(0.1, 0.09, 0.02), eyeMat);
    eye.position.set(x, 1.53, 0.26);
    eye.rotation.z = x > 0 ? 0.35 : -0.35;
    g.add(eye);
    eyes.push(eye);
  }

  // Grinsen
  const teeth = new THREE.Mesh(new THREE.BoxGeometry(0.26, 0.06, 0.02), bone);
  teeth.position.set(0, 1.37, 0.26);
  g.add(teeth);

  // Flügel (Pivot für Flattern)
  const wings = [];
  for (const side of [-1, 1]) {
    const pivot = new THREE.Group();
    pivot.position.set(0.36 * side, 1.15, -0.28);
    const wing = new THREE.Mesh(new THREE.BoxGeometry(0.62, 0.4, 0.05), dark);
    wing.position.x = 0.34 * side;
    pivot.add(wing);
    g.add(pivot);
    wings.push(pivot);
  }

  // Krallen-Ärmchen
  const arms = [];
  for (const side of [-1, 1]) {
    const pivot = new THREE.Group();
    pivot.position.set(0.42 * side, 1.05, 0.1);
    const arm = new THREE.Mesh(new THREE.BoxGeometry(0.16, 0.42, 0.16), bodyMat);
    arm.position.y = -0.2;
    const claw = new THREE.Mesh(new THREE.ConeGeometry(0.07, 0.18, 4), bone);
    claw.position.y = -0.48;
    claw.rotation.x = Math.PI;
    pivot.add(arm, claw);
    g.add(pivot);
    arms.push(pivot);
  }

  // Schweif
  const tail = new THREE.Mesh(new THREE.ConeGeometry(0.1, 0.55, 5), bodyMat);
  tail.position.set(0, 0.6, -0.4);
  tail.rotation.x = 2.4;
  g.add(tail);

  // HP-Balken über dem Kopf (Billboard); bei großen Gegnern nicht zu hoch
  const hpGroup = new THREE.Group();
  hpGroup.position.y = 2.35 / Math.sqrt(tier.scale);
  const hpBg = new THREE.Mesh(
    new THREE.PlaneGeometry(1.0, 0.12),
    new THREE.MeshBasicMaterial({ color: 0x14181f, transparent: true, opacity: 0.7 })
  );
  const fillGeo = new THREE.PlaneGeometry(0.94, 0.07);
  fillGeo.translate(0.47, 0, 0); // links verankert, damit scale.x schrumpft
  const hpFill = new THREE.Mesh(
    fillGeo,
    new THREE.MeshBasicMaterial({ color: 0xff5252 })
  );
  hpFill.position.set(-0.47, 0, 0.01);
  hpGroup.add(hpBg, hpFill);
  g.add(hpGroup);

  g.scale.setScalar(tier.scale);
  g.traverse((o) => {
    if (o.isMesh) o.castShadow = true;
  });

  return { group: g, bodyMat, eyes, wings, arms, hpGroup, hpFill };
}

class Enemy {
  constructor(scene, home, tierName) {
    this.tier = TIERS[tierName];
    this.home = home.clone();
    const parts = buildDevil(this.tier);
    this.group = parts.group;
    this.parts = parts;
    scene.add(this.group);

    this.hp = this.tier.hp;
    this.xp = this.tier.xp;
    this.state = 'idle';
    this.stateT = 0;
    this.wanderTarget = home.clone();
    this.wanderTimer = 0;
    this.flashT = 0;
    this.respawnT = 0;
    this.phase = Math.random() * Math.PI * 2;
    this.time = Math.random() * 10;

    this.group.position.copy(home);
  }

  get alive() {
    return this.state !== 'dead' && this.state !== 'waiting';
  }

  get pos() {
    return this.group.position;
  }

  takeDamage(dmg, fromPos) {
    if (!this.alive) return false;
    this.hp -= dmg;
    this.flashT = 0.14;

    // leichter Rückstoß vom Angreifer weg
    const dx = this.pos.x - fromPos.x;
    const dz = this.pos.z - fromPos.z;
    const len = Math.hypot(dx, dz) || 1;
    this.pos.x += (dx / len) * 0.3;
    this.pos.z += (dz / len) * 0.3;

    // aufwecken
    if (this.state === 'idle') this._setState('chase');

    if (this.hp <= 0) {
      this._setState('dead');
      return true; // getötet
    }
    return false;
  }

  _setState(s) {
    this.state = s;
    this.stateT = 0;
  }

  _moveToward(target, speed, dt) {
    const dx = target.x - this.pos.x;
    const dz = target.z - this.pos.z;
    const len = Math.hypot(dx, dz);
    if (len < 0.05) return;
    this.pos.x += (dx / len) * speed * dt;
    this.pos.z += (dz / len) * speed * dt;
    this.group.rotation.y = Math.atan2(dx, dz);
  }

  update(dt, player, world, camera) {
    this.time += dt;
    this.stateT += dt;

    if (this.state === 'waiting') {
      this.respawnT -= dt;
      if (this.respawnT <= 0) this._respawn();
      return;
    }

    if (this.state === 'dead') {
      // versinken und schrumpfen
      const k = Math.min(1, this.stateT / 0.9);
      this.group.scale.setScalar(this.tier.scale * (1 - k * 0.8));
      this.group.position.y = this._hoverY() - k * 1.6;
      this.group.rotation.z = k * 1.2;
      if (k >= 1) {
        this.group.visible = false;
        this._setState('waiting');
        this.respawnT = 12;
      }
      return;
    }

    const toPlayer = Math.hypot(
      player.group.position.x - this.pos.x,
      player.group.position.z - this.pos.z
    );

    switch (this.state) {
      case 'idle': {
        this.wanderTimer -= dt;
        if (this.wanderTimer <= 0) {
          this.wanderTimer = 2.5 + Math.random() * 3;
          this.wanderTarget.set(
            this.home.x + (Math.random() - 0.5) * 8,
            0,
            this.home.z + (Math.random() - 0.5) * 8
          );
        }
        this._moveToward(this.wanderTarget, 1.2, dt);
        if (toPlayer < AGGRO_RANGE && !player.dead) this._setState('chase');
        break;
      }
      case 'chase': {
        if (player.dead || toPlayer > LEASH_RANGE) {
          this._setState('idle');
          this.wanderTarget.copy(this.home);
          break;
        }
        if (toPlayer < ATTACK_RANGE) {
          this._setState('windup');
        } else {
          this._moveToward(player.group.position, this.tier.speed, dt);
        }
        break;
      }
      case 'windup': {
        // Telegraph: aufbäumen, Arme hoch
        this._face(player.group.position);
        if (this.stateT > 0.45) {
          if (toPlayer < HIT_RANGE && !player.dead) {
            player.takeDamage(this.tier.dmg, this.pos);
          }
          this._setState('cooldown');
        }
        break;
      }
      case 'cooldown': {
        if (this.stateT > 0.9) {
          this._setState(toPlayer < AGGRO_RANGE * 1.5 ? 'chase' : 'idle');
        }
        break;
      }
    }

    this._collide(world);
    this._animate(dt);

    // Aufblitzen bei Treffer
    if (this.flashT > 0) {
      this.flashT -= dt;
      this.parts.bodyMat.emissive.setHex(0xffffff);
      this.parts.bodyMat.emissiveIntensity = this.flashT > 0 ? 0.8 : 0;
    } else {
      this.parts.bodyMat.emissiveIntensity = 0;
    }

    // HP-Balken zur Kamera drehen + Füllstand
    this.parts.hpGroup.quaternion.copy(this.group.quaternion).invert();
    this.parts.hpGroup.quaternion.multiply(camera.quaternion);
    this.parts.hpFill.scale.x = Math.max(0.001, this.hp / this.tier.hp);
  }

  _face(target) {
    this.group.rotation.y = Math.atan2(target.x - this.pos.x, target.z - this.pos.z);
  }

  _hoverY() {
    return 0.35 + Math.sin(this.time * 3 + this.phase) * 0.12;
  }

  _animate(dt) {
    this.group.position.y = this._hoverY();

    // Flügel flattern
    const flapSpeed = this.state === 'chase' ? 16 : 9;
    const flap = 0.45 + Math.sin(this.time * flapSpeed) * 0.5;
    this.parts.wings[0].rotation.z = flap;
    this.parts.wings[1].rotation.z = -flap;

    // Windup-Telegraph: Arme heben, nach vorn lehnen
    const windup = this.state === 'windup' ? Math.min(1, this.stateT / 0.45) : 0;
    this.parts.arms[0].rotation.x = -windup * 2.2;
    this.parts.arms[1].rotation.x = -windup * 2.2;
    this.group.rotation.x = windup * 0.25;
    if (this.state !== 'windup') this.group.rotation.x = 0;
  }

  _collide(world) {
    const p = this.pos;
    for (const ob of world.obstacles) {
      const dx = p.x - ob.x;
      const dz = p.z - ob.z;
      const minDist = ob.radius + 0.5;
      const distSq = dx * dx + dz * dz;
      if (distSq < minDist * minDist && distSq > 0.0001) {
        const dist = Math.sqrt(distSq);
        p.x = ob.x + (dx / dist) * minDist;
        p.z = ob.z + (dz / dist) * minDist;
      }
    }
    const len = Math.hypot(p.x, p.z);
    if (len > world.bounds) {
      p.x = (p.x / len) * world.bounds;
      p.z = (p.z / len) * world.bounds;
    }
  }

  _respawn() {
    this.hp = this.tier.hp;
    this.group.visible = true;
    this.group.scale.setScalar(this.tier.scale);
    this.group.rotation.set(0, 0, 0);
    this.group.position.copy(this.home);
    this._setState('idle');
  }
}

export class EnemyManager {
  constructor(scene, world, { ui, effects, camera, onKill }) {
    this.world = world;
    this.ui = ui;
    this.effects = effects;
    this.camera = camera;
    this.onKill = onKill;
    this.enemies = [];

    // Feste Platzierung (Seed), große Devils weiter draußen
    const rng = mulberry32(7);
    for (let i = 0; i < 11; i++) {
      const angle = rng() * Math.PI * 2;
      const dist = 16 + rng() * 32;
      const home = new THREE.Vector3(Math.cos(angle) * dist, 0, Math.sin(angle) * dist);
      const tier = dist > 36 ? 'big' : 'normal';
      this.enemies.push(new Enemy(scene, home, tier));
    }
  }

  // Schwertschlag des Spielers auslösen
  playerStrike(player) {
    const fwdX = Math.sin(player.heading);
    const fwdZ = Math.cos(player.heading);
    const p = player.group.position;

    for (const enemy of this.enemies) {
      if (!enemy.alive) continue;
      const dx = enemy.pos.x - p.x;
      const dz = enemy.pos.z - p.z;
      const dist = Math.hypot(dx, dz);
      if (dist > 3.0) continue;

      // Nur Gegner im Winkel vor dem Spieler
      const dot = (dx * fwdX + dz * fwdZ) / (dist || 1);
      if (dot < 0.3) continue;

      const dmg = player.damage + Math.floor(Math.random() * 7) - 3;
      const killed = enemy.takeDamage(dmg, p);

      const sparkPos = enemy.pos.clone();
      sparkPos.y = 1.2;
      this.effects.hitSpark(sparkPos);
      const numPos = enemy.pos.clone();
      numPos.y = 2.2;
      this.ui.damageNumber(numPos, this.camera, `${dmg}`, killed ? 'dmg-kill' : '');

      if (killed) this.onKill(enemy);
    }
  }

  update(dt, player) {
    for (const enemy of this.enemies) {
      enemy.update(dt, player, this.world, this.camera);
    }

    // Gegner nicht ineinander stapeln
    for (let i = 0; i < this.enemies.length; i++) {
      const a = this.enemies[i];
      if (!a.alive) continue;
      for (let j = i + 1; j < this.enemies.length; j++) {
        const b = this.enemies[j];
        if (!b.alive) continue;
        const dx = b.pos.x - a.pos.x;
        const dz = b.pos.z - a.pos.z;
        const distSq = dx * dx + dz * dz;
        if (distSq < 1.2 * 1.2 && distSq > 0.0001) {
          const dist = Math.sqrt(distSq);
          const push = (1.2 - dist) / 2;
          a.pos.x -= (dx / dist) * push;
          a.pos.z -= (dz / dist) * push;
          b.pos.x += (dx / dist) * push;
          b.pos.z += (dz / dist) * push;
        }
      }
    }
  }
}
