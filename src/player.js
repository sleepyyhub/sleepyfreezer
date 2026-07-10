import * as THREE from 'three';
import { toon } from './toon.js';

const WALK_SPEED = 7;
const SPRINT_SPEED = 12;
const PLAYER_RADIUS = 0.5;

// Angriff: Ausholen -> Schlag -> Ausklingen
const ATTACK_DUR = 0.42;
const STRIKE_T = 0.16;

// kürzester Weg zwischen zwei Winkeln
function lerpAngle(a, b, t) {
  let d = (b - a) % (Math.PI * 2);
  if (d > Math.PI) d -= Math.PI * 2;
  if (d < -Math.PI) d += Math.PI * 2;
  return a + d * t;
}

// Anime-Schwertkämpfer "Kaito" aus Low-Poly-Boxen (schaut Richtung +Z)
function buildCharacter() {
  const g = new THREE.Group();

  const skin = toon(0xffd9b3);
  const hair = toon(0x2b2b3a);
  const jacket = toon(0xe63946);
  const pants = toon(0x2d3561);
  const dark = toon(0x22242e);

  // Torso + Schal
  const torso = new THREE.Mesh(new THREE.BoxGeometry(0.7, 0.85, 0.4), jacket);
  torso.position.y = 1.15;
  const scarf = new THREE.Mesh(new THREE.BoxGeometry(0.55, 0.18, 0.45), toon(0xf1f3f5));
  scarf.position.y = 1.62;
  g.add(torso, scarf);

  // Kopf + Haare + Pony
  const head = new THREE.Mesh(new THREE.BoxGeometry(0.55, 0.5, 0.5), skin);
  head.position.y = 1.98;
  const hairTop = new THREE.Mesh(new THREE.BoxGeometry(0.62, 0.26, 0.58), hair);
  hairTop.position.y = 2.25;
  const bangs = new THREE.Mesh(new THREE.BoxGeometry(0.62, 0.2, 0.12), hair);
  bangs.position.set(0, 2.12, 0.26);
  const spike = new THREE.Mesh(new THREE.ConeGeometry(0.16, 0.42, 4), hair);
  spike.position.set(0.14, 2.5, -0.08);
  spike.rotation.z = -0.35;
  g.add(head, hairTop, bangs, spike);

  // Augen (kleine dunkle Flächen vorne am Kopf)
  const eyeGeo = new THREE.BoxGeometry(0.07, 0.12, 0.02);
  for (const x of [-0.13, 0.13]) {
    const eye = new THREE.Mesh(eyeGeo, dark);
    eye.position.set(x, 1.98, 0.26);
    g.add(eye);
  }

  // Arme (Pivot an der Schulter)
  function makeArm(side) {
    const pivot = new THREE.Group();
    pivot.position.set(0.45 * side, 1.5, 0);
    const arm = new THREE.Mesh(new THREE.BoxGeometry(0.22, 0.68, 0.22), jacket);
    arm.position.y = -0.34;
    const hand = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.18, 0.2), skin);
    hand.position.y = -0.76;
    pivot.add(arm, hand);
    return pivot;
  }
  const armL = makeArm(-1);
  const armR = makeArm(1);
  g.add(armL, armR);

  // Katana in der rechten Hand
  const sword = new THREE.Group();
  sword.position.set(0, -0.78, 0.12);
  const handle = new THREE.Mesh(new THREE.BoxGeometry(0.07, 0.3, 0.07), dark);
  const guard = new THREE.Mesh(new THREE.BoxGeometry(0.2, 0.04, 0.2), toon(0xc9a227));
  guard.position.y = 0.16;
  const blade = new THREE.Mesh(new THREE.BoxGeometry(0.06, 1.05, 0.13), toon(0xd8e0e8));
  blade.position.y = 0.72;
  sword.add(handle, guard, blade);
  armR.add(sword);

  // Beine (Pivot an der Hüfte)
  function makeLeg(side) {
    const pivot = new THREE.Group();
    pivot.position.set(0.18 * side, 0.75, 0);
    const leg = new THREE.Mesh(new THREE.BoxGeometry(0.26, 0.72, 0.26), pants);
    leg.position.y = -0.38;
    const shoe = new THREE.Mesh(new THREE.BoxGeometry(0.27, 0.14, 0.36), dark);
    shoe.position.set(0, -0.72, 0.05);
    pivot.add(leg, shoe);
    return pivot;
  }
  const legL = makeLeg(-1);
  const legR = makeLeg(1);
  g.add(legL, legR);

  g.traverse((o) => {
    if (o.isMesh) o.castShadow = true;
  });

  return { group: g, armL, armR, legL, legR, torso };
}

export class Player {
  constructor(scene) {
    const parts = buildCharacter();
    this.group = parts.group;
    this.parts = parts;
    this.heading = Math.PI; // Start: von der Kamera weg schauen (Richtung -Z)
    this.animTime = 0;
    this.moving = false;

    // Kampf & RPG-Werte
    this.maxHp = 100;
    this.hp = this.maxHp;
    this.damage = 12;
    this.level = 1;
    this.xp = 0;
    this.xpNext = 40;
    this.dead = false;
    this.deathT = 0;
    this.attackT = -1; // -1 = kein Angriff aktiv
    this.didStrike = false; // genau im Frame des Treffers true

    // Callbacks (werden in main.js verdrahtet)
    this.onStatsChanged = null;
    this.onDamaged = null;
    this.onDeath = null;
    this.onLevelUp = null;

    this.group.position.set(0, 0, 0);
    this.group.rotation.y = this.heading;
    scene.add(this.group);

    this._dir = new THREE.Vector3();
    this._forward = new THREE.Vector3();
    this._right = new THREE.Vector3();
  }

  tryAttack() {
    if (this.dead || this.attackT >= 0) return;
    this.attackT = 0;
  }

  takeDamage(dmg, fromPos) {
    if (this.dead) return;
    this.hp -= dmg;

    // Rückstoß vom Angreifer weg
    const dx = this.group.position.x - fromPos.x;
    const dz = this.group.position.z - fromPos.z;
    const len = Math.hypot(dx, dz) || 1;
    this.group.position.x += (dx / len) * 0.9;
    this.group.position.z += (dz / len) * 0.9;

    this.onDamaged?.(dmg);
    this.onStatsChanged?.();

    if (this.hp <= 0) {
      this.hp = 0;
      this.dead = true;
      this.deathT = 0;
      this.attackT = -1;
      this.onDeath?.();
    }
  }

  gainXp(amount) {
    this.xp += amount;
    while (this.xp >= this.xpNext) {
      this.xp -= this.xpNext;
      this.level++;
      this.xpNext = Math.round(this.xpNext * 1.35);
      this.maxHp += 15;
      this.hp = this.maxHp; // Level-Up heilt komplett
      this.damage += 3;
      this.onLevelUp?.();
    }
    this.onStatsChanged?.();
  }

  update(dt, input, cameraYaw, world) {
    this.didStrike = false;

    // Tod: umfallen, dann am Spawn wiederbeleben
    if (this.dead) {
      this.deathT += dt;
      this.group.rotation.x = -Math.min(1, this.deathT / 0.35) * (Math.PI / 2) * 0.9;
      if (this.deathT > 2.2) {
        this.dead = false;
        this.hp = this.maxHp;
        this.group.position.set(0, 0, 2);
        this.group.rotation.x = 0;
        this.heading = Math.PI;
        this.group.rotation.y = this.heading;
        this.onStatsChanged?.();
      }
      return;
    }

    const axis = input.axis;
    this.moving = axis.x !== 0 || axis.z !== 0;

    if (this.moving) {
      // Bewegungsrichtung relativ zur Kamera
      this._forward.set(-Math.sin(cameraYaw), 0, -Math.cos(cameraYaw));
      this._right.crossVectors(this._forward, THREE.Object3D.DEFAULT_UP);
      this._dir
        .set(0, 0, 0)
        .addScaledVector(this._forward, axis.z)
        .addScaledVector(this._right, axis.x)
        .normalize();

      const speed = input.sprint ? SPRINT_SPEED : WALK_SPEED;
      this.group.position.addScaledVector(this._dir, speed * dt);

      // Figur in Laufrichtung drehen
      const target = Math.atan2(this._dir.x, this._dir.z);
      this.heading = lerpAngle(this.heading, target, 1 - Math.pow(0.00001, dt));
      this.group.rotation.y = this.heading;

      this.animTime += dt * (input.sprint ? 14 : 10);
    } else {
      this.animTime += dt * 2;
    }

    // Angriff fortschreiben; Treffer-Frame markieren
    if (this.attackT >= 0) {
      const prev = this.attackT;
      this.attackT += dt;
      if (prev < STRIKE_T && this.attackT >= STRIKE_T) this.didStrike = true;

      // kleiner Lunge nach vorn während des Schlags (Treffer verbinden besser)
      if (this.attackT > 0.08 && this.attackT < 0.26) {
        this.group.position.x += Math.sin(this.heading) * 4.5 * dt;
        this.group.position.z += Math.cos(this.heading) * 4.5 * dt;
      }

      if (this.attackT >= ATTACK_DUR) this.attackT = -1;
    }

    this._collide(world);
    this._animate();
  }

  _collide(world) {
    const p = this.group.position;

    // Hindernisse (Kreis-Kollision, sanft herausschieben)
    for (const ob of world.obstacles) {
      const dx = p.x - ob.x;
      const dz = p.z - ob.z;
      const minDist = ob.radius + PLAYER_RADIUS;
      const distSq = dx * dx + dz * dz;
      if (distSq < minDist * minDist && distSq > 0.0001) {
        const dist = Math.sqrt(distSq);
        p.x = ob.x + (dx / dist) * minDist;
        p.z = ob.z + (dz / dist) * minDist;
      }
    }

    // Weltgrenze
    const len = Math.hypot(p.x, p.z);
    if (len > world.bounds) {
      p.x = (p.x / len) * world.bounds;
      p.z = (p.z / len) * world.bounds;
    }
  }

  _animate() {
    const { armL, armR, legL, legR, torso } = this.parts;
    const t = this.animTime;
    const attacking = this.attackT >= 0;

    if (this.moving) {
      const swing = Math.sin(t) * 0.65;
      legL.rotation.x = swing;
      legR.rotation.x = -swing;
      armL.rotation.x = -swing * 0.8;
      if (!attacking) armR.rotation.x = swing * 0.8;
      this.group.position.y = Math.abs(Math.sin(t)) * 0.08;
    } else {
      // Idle: sanftes Atmen, Arme locker
      legL.rotation.x = 0;
      legR.rotation.x = 0;
      armL.rotation.x = Math.sin(t) * 0.05;
      if (!attacking) armR.rotation.x = -Math.sin(t) * 0.05;
      this.group.position.y = 0;
      torso.scale.y = 1 + Math.sin(t) * 0.01;
    }

    // Schwert-Schlag: ausholen -> nach vorn schlagen -> zurück
    if (attacking) {
      const a = this.attackT;
      let armX;
      let twist;
      if (a < 0.1) {
        const k = a / 0.1;
        armX = -2.5 * k; // über den Kopf ausholen
        twist = 0.35 * k;
      } else if (a < 0.24) {
        const k = (a - 0.1) / 0.14;
        armX = -2.5 + 3.4 * k; // Schlag nach vorn-unten
        twist = 0.35 - 0.8 * k;
      } else {
        const k = (a - 0.24) / (ATTACK_DUR - 0.24);
        armX = 0.9 * (1 - k); // ausklingen
        twist = -0.45 * (1 - k);
      }
      armR.rotation.x = armX;
      torso.rotation.y = twist;
    } else {
      torso.rotation.y = 0;
    }
  }
}
