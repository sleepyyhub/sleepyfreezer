import * as THREE from 'three';
import type { EnemyEntity } from '@/sim/entities';
import type { SimWorld } from '@/sim/World';
import type { MaterialFactory } from '../materials/toon';
import { buildPlayerRig } from '../models/player';
import { buildEnemyRig } from '../models/enemies';
import { disposeRig, type Rig } from '../models/skeleton';
import { EnemyAnimator, PlayerAnimator } from '../anim/CharacterAnimator';

interface EnemyView {
  rig: Rig;
  anim: EnemyAnimator;
  bar: THREE.Group;
  barFill: THREE.Mesh;
  telegraph: THREE.Mesh;
  /** Interpolated render position, distinct from the sim's authoritative one. */
  rx: number;
  rz: number;
  ry: number;
  ryaw: number;
  lastHp: number;
}

const TELEGRAPH_RED = 0xff3b3b;
const TELEGRAPH_YELLOW = 0xffcc33;

/**
 * Binds sim entities to animated rigs. The sim is the source of truth; this
 * layer reads it, interpolates for smoothness, and hands state to the
 * animators. It never poses joints directly — that is the Animator's job.
 */
export class EntityViews {
  private playerRig: Rig;
  private playerAnim: PlayerAnimator;
  private enemyViews = new Map<number, EnemyView>();
  private lockOnRing: THREE.Mesh;
  private disposables: (THREE.BufferGeometry | THREE.Material)[] = [];

  private prx = 0;
  private prz = 0;
  private pry = 0;
  private pryaw = 0;
  private playerSpeed = 0;

  constructor(
    private scene: THREE.Scene,
    private mats: MaterialFactory,
  ) {
    this.playerRig = buildPlayerRig(mats);
    this.playerAnim = new PlayerAnimator(this.playerRig);
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

  /** Total triangles across every live rig — surfaced for the perf budget. */
  get triangleCount(): number {
    let n = this.playerRig.triangles;
    for (const v of this.enemyViews.values()) n += v.rig.triangles;
    return n;
  }

  sync(world: SimWorld, dt: number) {
    this.syncPlayer(world, dt);
    this.syncEnemies(world, dt);
    this.syncLockOn(world);
  }

  // ------------------------------------------------------------- player

  private syncPlayer(world: SimWorld, dt: number) {
    const p = world.player;

    // Exponential damping is frame-rate independent; a fixed lerp factor is
    // the classic source of "combat feels different on my laptop".
    const k = 1 - Math.exp(-24 * dt);
    const prevX = this.prx;
    const prevZ = this.prz;
    this.prx += (p.x - this.prx) * k;
    this.prz += (p.z - this.prz) * k;
    this.pry += (p.y - this.pry) * k;
    this.pryaw = dampAngle(this.pryaw, p.yaw, 18, dt);

    // Ground speed drives the locomotion blend. Measured from the rendered
    // position so it matches what the player actually sees.
    const moved = Math.hypot(this.prx - prevX, this.prz - prevZ);
    const instant = dt > 0 ? moved / dt : 0;
    this.playerSpeed += (instant - this.playerSpeed) * (1 - Math.exp(-14 * dt));

    this.playerRig.root.position.set(this.prx, this.pry, this.prz);
    this.playerRig.root.rotation.y = this.pryaw;
    this.playerRig.root.visible = true;

    // Head/torso turn toward the lock-on target, as an offset from facing.
    let aimOffset = 0;
    if (world.lockOnTarget) {
      const t = world.enemies.find((e) => e.id === world.lockOnTarget);
      if (t) {
        aimOffset = shortestAngle(Math.atan2(t.x - p.x, t.z - p.z) - this.pryaw);
      }
    }

    this.playerAnim.update(p, this.playerSpeed, dt, aimOffset);
  }

  // ------------------------------------------------------------- enemies

  private syncEnemies(world: SimWorld, dt: number) {
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

      // Detect damage here rather than subscribing to the event bus, so the
      // flinch can never fire for an entity whose view does not exist yet.
      if (e.hp < view.lastHp) view.anim.flinch(e);
      view.lastHp = e.hp;

      view.anim.update(e, dt);
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

    // Billboarded two-quad health bar. toneMapped/fog off because this is UI
    // that happens to live in world space — ACES and the green fog wash it
    // into an unreadable maroon otherwise.
    const bar = new THREE.Group();
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
      anim: new EnemyAnimator(rig, e),
      bar,
      barFill: fill,
      telegraph,
      rx: e.x,
      rz: e.z,
      ry: e.y,
      ryaw: e.yaw,
      lastHp: e.hp,
    };
  }

  private updateHealthBar(e: EnemyEntity, view: EnemyView, world: SimWorld) {
    // Bosses use the HUD bar; a floating bar would just be redundant clutter.
    const engaged = e.state !== 'idle' && e.state !== 'dead';
    const damaged = e.hp < e.maxHp;
    view.bar.visible =
      !e.isBoss && (engaged || damaged) && e.state !== 'dead' && world.player.action !== 'dead';
    if (!view.bar.visible) return;

    view.bar.position.set(view.rx, view.ry + view.rig.height + 0.4, view.rz);
    // Scale the bar to the creature: a 1m grasshopper wearing a bar sized for
    // a 3m warden reads as UI clutter rather than as that enemy's health.
    const barScale = clamp(view.rig.height / 2.2, 0.55, 1.25);
    view.bar.scale.setScalar(barScale);
    view.barFill.scale.x = Math.max(0, e.hp / e.maxHp);
    (view.barFill.material as THREE.MeshBasicMaterial).color.setHex(
      e.state === 'stagger' ? 0xffd166 : 0xff5d5d,
    );
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
    view.telegraph.scale.setScalar(atk.range * (0.35 + t * 0.65));

    const mat = view.telegraph.material as THREE.MeshBasicMaterial;
    mat.color.setHex(atk.multiplier >= 1.5 ? TELEGRAPH_RED : TELEGRAPH_YELLOW);
    mat.opacity = 0.2 + t * 0.45;
  }

  private syncLockOn(world: SimWorld) {
    const target = world.lockOnTarget ? this.enemyViews.get(world.lockOnTarget) : undefined;
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
    this.scene.remove(view.bar, view.telegraph);
    disposeRig(view.rig);
  }

  dispose() {
    for (const v of this.enemyViews.values()) this.destroyEnemyView(v);
    this.enemyViews.clear();
    this.scene.remove(this.lockOnRing);
    disposeRig(this.playerRig);
    for (const d of this.disposables) d.dispose();
    this.disposables.length = 0;
  }
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

function dampAngle(current: number, target: number, k: number, dt: number): number {
  return current + shortestAngle(target - current) * (1 - Math.exp(-k * dt));
}

function shortestAngle(diff: number): number {
  let d = diff;
  while (d > Math.PI) d -= Math.PI * 2;
  while (d < -Math.PI) d += Math.PI * 2;
  return d;
}
