import * as THREE from 'three';
import type { EnemyEntity, PlayerEntity } from '@/sim/entities';
import type { SimWorld } from '@/sim/World';
import { MOVES, DODGE } from '@/sim/moves';
import type { MaterialFactory } from '../materials/toon';
import { buildEnemyRig, buildPlayerRig, type CharacterRig } from './characters';

interface EnemyView {
  rig: CharacterRig;
  bar: THREE.Group;
  barFill: THREE.Mesh;
  telegraph: THREE.Mesh;
  /** Interpolated render position, distinct from the sim's authoritative one. */
  rx: number;
  rz: number;
  ry: number;
  ryaw: number;
}

const TELEGRAPH_RED = 0xff3b3b;
const TELEGRAPH_YELLOW = 0xffcc33;

/**
 * Binds sim entities to scene objects. The sim is the source of truth; this
 * layer only reads it, interpolates for smoothness, and poses the rigs.
 */
export class EntityViews {
  private playerRig: CharacterRig;
  private enemyViews = new Map<number, EnemyView>();
  private lockOnRing: THREE.Mesh;
  private disposables: (THREE.BufferGeometry | THREE.Material)[] = [];

  private prx = 0;
  private prz = 0;
  private pry = 0;
  private pryaw = 0;

  constructor(
    private scene: THREE.Scene,
    private mats: MaterialFactory,
  ) {
    this.playerRig = buildPlayerRig(mats);
    scene.add(this.playerRig.root);

    const ringGeo = new THREE.RingGeometry(0.75, 0.95, 20);
    ringGeo.rotateX(-Math.PI / 2);
    const ringMat = new THREE.MeshBasicMaterial({
      color: 0xfff2a8,
      transparent: true,
      opacity: 0.85,
      depthWrite: false,
      toneMapped: false,
      fog: false,
    });
    this.lockOnRing = new THREE.Mesh(ringGeo, ringMat);
    this.lockOnRing.visible = false;
    scene.add(this.lockOnRing);
    this.disposables.push(ringGeo, ringMat);
  }

  get playerObject(): THREE.Object3D {
    return this.playerRig.root;
  }

  /**
   * @param alpha fraction of a sim step already elapsed, used to smooth render
   *              position between fixed-step updates.
   */
  sync(world: SimWorld, dt: number, alpha: number) {
    this.syncPlayer(world, dt, alpha);
    this.syncEnemies(world, dt, alpha);
    this.syncLockOn(world);
  }

  // ------------------------------------------------------------- player

  private syncPlayer(world: SimWorld, dt: number, _alpha: number) {
    const p = world.player;
    const rig = this.playerRig;

    // Exponential damping is frame-rate independent; a fixed lerp factor is
    // the classic source of "combat feels different on my laptop".
    const k = 1 - Math.exp(-24 * dt);
    this.prx += (p.x - this.prx) * k;
    this.prz += (p.z - this.prz) * k;
    this.pry += (p.y - this.pry) * k;
    this.pryaw = dampAngle(this.pryaw, p.yaw, 18, dt);

    rig.root.position.set(this.prx, this.pry, this.prz);
    rig.root.rotation.y = this.pryaw;
    rig.root.visible = p.action !== 'dead';

    this.posePlayer(p, world.time);
  }

  private posePlayer(p: PlayerEntity, time: number) {
    const rig = this.playerRig;
    const rest = () => {
      rig.armL.rotation.set(0, 0, 0.12);
      rig.armR.rotation.set(0, 0, -0.12);
      rig.legL.rotation.set(0, 0, 0);
      rig.legR.rotation.set(0, 0, 0);
      rig.torso.rotation.set(0, 0, 0);
      rig.torso.position.y = 0.92;
    };

    if (p.action === 'attack' && p.currentMove) {
      const mv = MOVES[p.currentMove];
      const total = mv.startupS + mv.activeS + mv.recoverS;
      const t = Math.min(1, p.actionT / total);
      const swingPoint = mv.startupS / total;

      // Wind back during startup, snap through on the active frames, settle.
      const swing =
        t < swingPoint
          ? -0.9 * (t / swingPoint)
          : -0.9 + 3.2 * Math.min(1, (t - swingPoint) / 0.22);

      rest();
      if (p.currentMove === 'special') {
        rig.armL.rotation.set(-2.2, 0, 0.5);
        rig.armR.rotation.set(-2.2, 0, -0.5);
        rig.torso.rotation.x = -0.2;
      } else if (p.currentMove === 'heavy') {
        rig.armR.rotation.set(swing * 1.2, 0, -0.3);
        rig.armL.rotation.set(swing * 0.5, 0, 0.3);
        rig.torso.rotation.y = -swing * 0.35;
      } else {
        const side = p.currentMove === 'light2' ? -1 : 1;
        rig.armR.rotation.set(swing * side, 0, -0.2);
        rig.armL.rotation.set(-swing * side * 0.4, 0, 0.2);
        rig.torso.rotation.y = -swing * 0.25 * side;
      }
      return;
    }

    if (p.action === 'dodge') {
      const t = Math.min(1, p.actionT / DODGE.totalS);
      rest();
      rig.torso.rotation.x = -Math.sin(t * Math.PI) * 2.2;
      rig.torso.position.y = 0.92 - Math.sin(t * Math.PI) * 0.35;
      rig.armL.rotation.x = -1.6;
      rig.armR.rotation.x = -1.6;
      return;
    }

    if (p.action === 'hurt') {
      rest();
      rig.torso.rotation.x = 0.35;
      rig.armL.rotation.x = 0.6;
      rig.armR.rotation.x = 0.6;
      return;
    }

    // Idle / locomotion: a simple counter-swinging gait.
    const speed = Math.hypot(p.x - this.prx, p.z - this.prz);
    const moving = speed > 0.004;
    rest();
    if (moving) {
      const phase = time * 11;
      const amp = 0.7;
      rig.legL.rotation.x = Math.sin(phase) * amp;
      rig.legR.rotation.x = -Math.sin(phase) * amp;
      rig.armL.rotation.x = -Math.sin(phase) * amp * 0.8;
      rig.armR.rotation.x = Math.sin(phase) * amp * 0.8;
      rig.torso.position.y = 0.92 + Math.abs(Math.sin(phase)) * 0.05;
    } else {
      const breathe = Math.sin(time * 2.2) * 0.03;
      rig.torso.position.y = 0.92 + breathe;
      rig.armL.rotation.x = breathe * 0.5;
      rig.armR.rotation.x = -breathe * 0.5;
    }
  }

  // ------------------------------------------------------------- enemies

  private syncEnemies(world: SimWorld, dt: number, _alpha: number) {
    const seen = new Set<number>();

    for (const e of world.enemies) {
      seen.add(e.id);
      let view = this.enemyViews.get(e.id);
      if (!view) {
        view = this.createEnemyView(e);
        this.enemyViews.set(e.id, view);
      }

      const k = 1 - Math.exp(-22 * dt);
      view.rx += (e.x - view.rx) * k;
      view.rz += (e.z - view.rz) * k;
      view.ry += (e.y - view.ry) * k;
      view.ryaw = dampAngle(view.ryaw, e.yaw, 12, dt);

      view.rig.root.position.set(view.rx, view.ry, view.rz);
      view.rig.root.rotation.y = view.ryaw;

      this.poseEnemy(e, view, world.time);
      this.updateHealthBar(e, view, world);
      this.updateTelegraph(e, view);
    }

    for (const [id, view] of this.enemyViews) {
      if (seen.has(id)) continue;
      this.destroyEnemyView(view);
      this.enemyViews.delete(id);
    }
  }

  private createEnemyView(e: EnemyEntity): EnemyView {
    const rig = buildEnemyRig(this.mats, e.def.visual);
    rig.root.position.set(e.x, e.y, e.z);
    this.scene.add(rig.root);

    // Billboarded two-quad health bar. Cheap, and far more readable in a 3D
    // scene than a DOM element chasing a projected position.
    const bar = new THREE.Group();
    // toneMapped/fog off: these are UI drawn in world space. Left on, ACES
    // and the green fog wash them into dark maroon and they stop reading as
    // health at a glance.
    const bg = new THREE.Mesh(
      new THREE.PlaneGeometry(1.2, 0.14),
      new THREE.MeshBasicMaterial({
        color: 0x121a16,
        depthTest: false,
        transparent: true,
        opacity: 0.75,
        toneMapped: false,
        fog: false,
      }),
    );
    const fillGeo = new THREE.PlaneGeometry(1.16, 0.1);
    // Shift the pivot to the left edge so scaling drains the bar rightward.
    fillGeo.translate(0.58, 0, 0);
    const fill = new THREE.Mesh(
      fillGeo,
      new THREE.MeshBasicMaterial({
        color: 0xff5d5d,
        depthTest: false,
        toneMapped: false,
        fog: false,
        // Must be transparent even at full opacity: three renders the whole
        // opaque pass before the transparent one, so an opaque fill would be
        // drawn *under* its own transparent backing regardless of renderOrder.
        transparent: true,
        opacity: 1,
      }),
    );
    fill.position.x = -0.58;
    fill.position.z = 0.001;
    bar.add(bg, fill);
    // renderOrder does not propagate from a Group, so set it per mesh.
    bg.renderOrder = 998;
    fill.renderOrder = 999;
    bar.visible = false;
    this.scene.add(bar);

    const telGeo = new THREE.RingGeometry(0.2, 1, 24);
    telGeo.rotateX(-Math.PI / 2);
    // Telegraph colour is a fixed game-wide language (red = dodge). Tone
    // mapping it per-world would make that language drift between worlds.
    const telMat = new THREE.MeshBasicMaterial({
      color: TELEGRAPH_RED,
      transparent: true,
      opacity: 0.4,
      depthWrite: false,
      side: THREE.DoubleSide,
      toneMapped: false,
      fog: false,
    });
    const telegraph = new THREE.Mesh(telGeo, telMat);
    telegraph.visible = false;
    this.scene.add(telegraph);

    this.disposables.push(fillGeo, telGeo, telMat);

    return {
      rig,
      bar,
      barFill: fill,
      telegraph,
      rx: e.x,
      rz: e.z,
      ry: e.y,
      ryaw: e.yaw,
    };
  }

  private poseEnemy(e: EnemyEntity, view: EnemyView, time: number) {
    const rig = view.rig;
    const halo = rig.torso.getObjectByName('halo');
    if (halo) halo.rotation.z = time * 1.4;

    if (e.state === 'dead') {
      // Topple and sink rather than popping out of existence.
      const t = Math.min(1, (time - e.deadAt) / 0.6);
      rig.root.rotation.x = t * 1.5;
      rig.root.position.y = view.ry - t * 0.9;
      rig.root.scale.setScalar(e.def.visual.scale * (1 - t * 0.25));
      return;
    }

    if (e.state === 'stagger') {
      rig.torso.rotation.x = 0.5 + Math.sin(time * 30) * 0.06;
      rig.torso.rotation.z = Math.sin(time * 22) * 0.1;
      return;
    }

    if (e.state === 'windup' && e.currentAttack) {
      const t = Math.min(1, e.stateT / e.currentAttack.windupS);
      // Pull back further the longer the windup — the visual reads as loading.
      rig.torso.rotation.x = -0.5 * t;
      rig.torso.position.y = 0.2 + t * 0.15;
      return;
    }

    if (e.state === 'attack') {
      rig.torso.rotation.x = 0.6;
      rig.torso.position.y = 0.1;
      return;
    }

    rig.torso.rotation.set(0, 0, 0);
    const bob = e.state === 'aggro' ? Math.abs(Math.sin(time * 8)) * 0.07 : Math.sin(time * 1.8) * 0.03;
    rig.torso.position.y = (e.def.visual.shape === 'golem' ? 0.2 : 0.5) + bob;
  }

  private updateHealthBar(e: EnemyEntity, view: EnemyView, world: SimWorld) {
    // Bosses use the HUD bar; a floating bar would just be redundant clutter.
    const engaged = e.state !== 'idle' && e.state !== 'dead';
    const damaged = e.hp < e.maxHp;
    view.bar.visible = !e.isBoss && (engaged || damaged) && e.state !== 'dead';
    if (!view.bar.visible) return;

    view.bar.position.set(view.rx, view.ry + view.rig.height + 0.45, view.rz);
    const pct = Math.max(0, e.hp / e.maxHp);
    view.barFill.scale.x = pct;
    (view.barFill.material as THREE.MeshBasicMaterial).color.setHex(
      e.state === 'stagger' ? 0xffd166 : 0xff5d5d,
    );
    view.bar.visible = view.bar.visible && world.player.action !== 'dead';
  }

  private updateTelegraph(e: EnemyEntity, view: EnemyView) {
    const showing = e.state === 'windup' && e.currentAttack;
    view.telegraph.visible = !!showing;
    if (!showing || !e.currentAttack) return;

    const atk = e.currentAttack;
    const t = Math.min(1, e.stateT / atk.windupS);
    view.telegraph.position.set(view.rx, view.ry + 0.06, view.rz);
    view.telegraph.rotation.y = -view.ryaw;

    // The decal fills toward the real hitbox size, so "full" == "now".
    const scale = atk.range * (0.35 + t * 0.65);
    view.telegraph.scale.setScalar(scale);

    const mat = view.telegraph.material as THREE.MeshBasicMaterial;
    // Consistent language across the whole game: red = dodge.
    mat.color.setHex(atk.multiplier >= 1.5 ? TELEGRAPH_RED : TELEGRAPH_YELLOW);
    mat.opacity = 0.2 + t * 0.45;
  }

  private syncLockOn(world: SimWorld) {
    const target = world.lockOnTarget
      ? this.enemyViews.get(world.lockOnTarget)
      : undefined;
    this.lockOnRing.visible = !!target;
    if (!target) return;
    this.lockOnRing.position.set(target.rx, target.ry + 0.08, target.rz);
    this.lockOnRing.rotation.z += 0.02;
  }

  /** Billboard every bar toward the camera. Called once per frame. */
  faceCamera(camera: THREE.Camera) {
    for (const v of this.enemyViews.values()) {
      if (v.bar.visible) v.bar.quaternion.copy(camera.quaternion);
    }
  }

  private destroyEnemyView(view: EnemyView) {
    this.scene.remove(view.rig.root, view.bar, view.telegraph);
    view.rig.root.traverse((o) => {
      const m = o as THREE.Mesh;
      if (m.isMesh && m.geometry) m.geometry.dispose();
    });
  }

  dispose() {
    for (const v of this.enemyViews.values()) this.destroyEnemyView(v);
    this.enemyViews.clear();
    this.scene.remove(this.playerRig.root, this.lockOnRing);
    for (const d of this.disposables) d.dispose();
    this.disposables.length = 0;
  }
}

function dampAngle(current: number, target: number, k: number, dt: number): number {
  let diff = target - current;
  while (diff > Math.PI) diff -= Math.PI * 2;
  while (diff < -Math.PI) diff += Math.PI * 2;
  return current + diff * (1 - Math.exp(-k * dt));
}
