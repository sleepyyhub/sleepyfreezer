import * as THREE from 'three';
import { SimWorld, EMPTY_INTENT, type InputIntent } from '@/sim/World';
import { SPECIAL_COOLDOWN_S } from '@/sim/moves';
import { DROP_TABLE_MAP, getEnemy, getItemDef, getWorld, getZone, ITEM_MAP } from '@/content';
import { MaterialFactory } from '@/render/materials/toon';
import { ZoneScene, buildLighting } from '@/render/env/ZoneScene';
import { EntityViews } from '@/render/views/EntityViews';
import { CameraRig } from '@/render/CameraRig';
import { FloatingText } from '@/render/vfx/FloatingText';
import { Input } from './Input';
import { bus } from './EventBus';
import { useGame } from '@/ui/store/gameStore';
import { qualityFor, detectTier, type QualitySettings } from './quality';

const SIM_STEP = 1 / 60;
/** Clamp: a backgrounded tab or GC pause otherwise runs hundreds of steps at once. */
const MAX_FRAME_DELTA = 0.25;
const HUD_UPDATE_HZ = 15;

export class Game {
  private renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private rig: CameraRig;
  private world: SimWorld;
  private views: EntityViews;
  private zoneScene: ZoneScene;
  private materials: MaterialFactory;
  private input: Input;
  private floaters: FloatingText;
  private keyLight: THREE.DirectionalLight;
  private quality: QualitySettings;

  private acc = 0;
  private last = 0;
  private running = false;
  private rafId = 0;
  private hudAcc = 0;
  private fpsSamples: number[] = [];
  private unsubscribers: (() => void)[] = [];

  constructor(canvas: HTMLCanvasElement, uiRoot: HTMLElement) {
    const store = useGame.getState();
    const zone = getZone(store.character.currentWorld, store.character.currentZone);
    const world = getWorldPalette(store.character.currentWorld);

    this.quality = qualityFor(detectTier());

    this.renderer = new THREE.WebGLRenderer({
      canvas,
      antialias: this.quality.antialias,
      powerPreference: 'high-performance',
    });
    this.renderer.setPixelRatio(
      Math.min(window.devicePixelRatio, this.quality.maxPixelRatio),
    );
    this.renderer.setSize(window.innerWidth, window.innerHeight, false);
    this.renderer.shadowMap.enabled = this.quality.shadows;
    this.renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = world.exposure;

    this.scene.background = new THREE.Color(world.fog.color);
    // Exponential fog does double duty: atmosphere, and it hides the short
    // draw distance that keeps the frame budget in range.
    this.scene.fog = new THREE.FogExp2(world.fog.color, world.fog.density);

    this.materials = new MaterialFactory(world);

    this.world = new SimWorld({
      zone,
      character: store.character,
      itemDefs: ITEM_MAP,
      dropTables: DROP_TABLE_MAP,
      getEnemyDef: getEnemy,
    });
    this.world.syncPlayerStats(store.stats, true);

    this.zoneScene = new ZoneScene(
      zone,
      this.world.terrain,
      world,
      this.materials,
      { foliageFraction: this.quality.foliageFraction },
    );
    this.scene.add(this.zoneScene.group);

    const lighting = buildLighting(world);
    this.keyLight = lighting.key;
    this.keyLight.castShadow = this.quality.shadows;
    this.keyLight.shadow.mapSize.set(this.quality.shadowMapSize, this.quality.shadowMapSize);
    this.scene.add(lighting.group);

    this.rig = new CameraRig(window.innerWidth / window.innerHeight, this.world.terrain);
    this.rig.camera.far = this.quality.drawDistance;
    this.rig.camera.updateProjectionMatrix();

    this.views = new EntityViews(this.scene, this.materials);
    this.floaters = new FloatingText(uiRoot);
    this.input = new Input(canvas);

    this.wireEvents();
    window.addEventListener('resize', this.onResize);
  }

  // ---------------------------------------------------------------- events

  private wireEvents() {
    const store = () => useGame.getState();

    this.unsubscribers.push(
      bus.on('damage', ({ at, amount, isCrit, onPlayer }) => {
        this.floaters.spawn(isCrit ? `${amount}!` : `${amount}`, at, {
          color: onPlayer ? '#ff6b6b' : isCrit ? '#ffd166' : '#ffffff',
          size: onPlayer ? 22 : isCrit ? 28 : 20,
        });
        if (onPlayer) this.rig.shake(0.22);
        else if (isCrit) this.rig.shake(0.09);
      }),

      bus.on('staggered', ({ at }) => {
        this.floaters.spawn('STAGGER', at, { color: '#ffd166', size: 22, life: 1.1 });
        this.rig.shake(0.16);
      }),

      bus.on('dodgeSuccess', ({ at }) => {
        this.floaters.spawn('dodge', at, { color: '#8ff0d0', size: 16, life: 0.6 });
      }),

      bus.on('enemyKilled', ({ xp, drops, currency, isBoss, enemyId }) => {
        const s = store();
        s.recordKill(this.world.zone.id);
        const levels = s.grantXp(xp);
        s.grantDrops(drops, currency);

        this.floaters.spawn(
          `+${xp} XP`,
          { x: this.world.player.x, y: this.world.player.y + 2.4, z: this.world.player.z },
          { color: '#a5f3c9', size: 17, life: 1.1 },
        );

        for (const d of drops) {
          const def = getItemDef(d.defId);
          if (!def) continue;
          s.pushToast(
            `${def.name}${d.quantity > 1 ? ` x${d.quantity}` : ''}`,
            d.rarity === 'common' ? 'info' : 'good',
          );
        }

        if (levels > 0) {
          bus.emit('levelUp', {
            level: s.character.level + levels,
            statPoints: s.character.statPoints,
          });
        }

        if (isBoss) {
          s.setFlag(`boss.${enemyId}.killed`);
          s.pushToast(`${enemyId} defeated — the way opens`, 'good');
          this.rig.shake(0.4);
        }
      }),

      bus.on('levelUp', () => {
        const s = store();
        s.pushToast(`Level ${s.character.level}! +3 stat points`, 'good');
        // Level-ups heal to full: a level gained mid-fight should feel like a
        // reward, not a bar that silently got longer.
        this.world.syncPlayerStats(s.stats, true);
        this.floaters.spawn(
          'LEVEL UP',
          { x: this.world.player.x, y: this.world.player.y + 3, z: this.world.player.z },
          { color: '#ffe08a', size: 32, life: 1.6 },
        );
      }),

      bus.on('chestOpened', ({ chestId, drops, currency }) => {
        const s = store();
        s.grantDrops(drops, currency);
        this.zoneScene.markChestOpened(chestId);
        s.pushToast(`Chest opened — ${currency} zeni`, 'good');
        for (const d of drops) {
          const def = getItemDef(d.defId);
          if (def) s.pushToast(`${def.name}${d.quantity > 1 ? ` x${d.quantity}` : ''}`, 'good');
        }
      }),

      bus.on('bossEngaged', ({ name, maxHp }) => {
        store().setVitals({ bossName: name, bossHp: maxHp, bossMaxHp: maxHp });
        store().pushToast(`${name} blocks your path`, 'bad');
      }),

      bus.on('bossDisengaged', () => {
        store().setVitals({ bossName: null });
      }),

      bus.on('bossPhase', ({ phase, name }) => {
        store().pushToast(`${name} — Phase ${phase}`, 'bad');
        this.rig.shake(0.35);
      }),

      bus.on('playerDied', () => {
        store().setDead(true);
        this.input.releaseLock();
      }),

      bus.on('toast', ({ text, tone }) => store().pushToast(text, tone)),
    );

    // Gear and stat changes recompute derived stats; push them into the sim.
    this.unsubscribers.push(
      useGame.subscribe((s, prev) => {
        if (s.stats !== prev.stats) this.world.syncPlayerStats(s.stats);
        // Opening a panel must not leave the player mid-input in the world.
        const uiOpen = s.panel !== 'none' || s.dead;
        this.input.enabled = !uiOpen;
        if (uiOpen) this.input.releaseLock();
      }),
    );
  }

  // ---------------------------------------------------------------- loop

  start() {
    if (this.running) return;
    this.running = true;
    this.last = performance.now() / 1000;
    this.rafId = requestAnimationFrame(this.frame);
  }

  stop() {
    this.running = false;
    cancelAnimationFrame(this.rafId);
  }

  respawn() {
    this.world.respawnPlayer();
    const s = useGame.getState();
    this.world.syncPlayerStats(s.stats, true);
    s.setDead(false);
  }

  private frame = (nowMs: number) => {
    if (!this.running) return;
    this.rafId = requestAnimationFrame(this.frame);

    const now = nowMs / 1000;
    let dt = now - this.last;
    this.last = now;
    dt = Math.min(dt, MAX_FRAME_DELTA);
    this.acc += dt;

    // Camera runs on the render clock so it stays smooth above 60fps.
    const mouse = this.input.drainMouse();
    if (this.input.isLocked) this.rig.orbit(mouse.dx, mouse.dy);
    if (mouse.wheel) this.rig.zoom(mouse.wheel);

    let intent: InputIntent = EMPTY_INTENT;
    let steps = 0;
    while (this.acc >= SIM_STEP && steps < 6) {
      intent = this.input.snapshot((x, z) => this.rig.worldDirection(x, z));
      this.world.step(SIM_STEP, intent);
      this.acc -= SIM_STEP;
      steps++;
    }
    // Fell too far behind (background tab, heavy GC): drop the backlog rather
    // than fast-forwarding the fight the player wasn't watching.
    if (this.acc > SIM_STEP * 6) this.acc = 0;

    const alpha = this.acc / SIM_STEP;
    this.views.sync(this.world, dt, alpha);
    this.views.faceCamera(this.rig.camera);

    const lockTarget = this.world.lockOnTarget
      ? this.world.enemies.find((e) => e.id === this.world.lockOnTarget)
      : undefined;

    this.rig.update(
      dt,
      this.views.playerObject.position,
      lockTarget ? new THREE.Vector3(lockTarget.x, lockTarget.y, lockTarget.z) : null,
    );

    // Keep the shadow frustum glued to the player so a 1024 map stays sharp.
    const p = this.views.playerObject.position;
    this.keyLight.position.set(p.x + 40, p.y + 55, p.z + 25);
    this.keyLight.target.position.copy(p);
    this.keyLight.target.updateMatrixWorld();

    this.floaters.update(dt, this.rig.camera, window.innerWidth, window.innerHeight);
    this.renderer.render(this.scene, this.rig.camera);

    this.updateHud(dt);
  };

  /**
   * The HUD updates at 15Hz, not 60. Health numbers changing 15 times a second
   * are indistinguishable to a human and cost a quarter of the React work.
   */
  private updateHud(dt: number) {
    this.fpsSamples.push(1 / Math.max(dt, 0.0001));
    if (this.fpsSamples.length > 30) this.fpsSamples.shift();

    this.hudAcc += dt;
    if (this.hudAcc < 1 / HUD_UPDATE_HZ) return;
    this.hudAcc = 0;

    const p = this.world.player;
    const boss = this.world.activeBoss();
    const chest = this.world.nearestInteractable();
    const avgFps =
      this.fpsSamples.reduce((a, b) => a + b, 0) / Math.max(1, this.fpsSamples.length);

    useGame.getState().setVitals({
      hp: Math.max(0, Math.round(p.hp)),
      maxHp: p.stats.maxHp,
      stamina: Math.round(p.stamina),
      maxStamina: p.stats.maxStamina,
      specialCooldown: p.specialCooldown,
      specialCooldownMax: SPECIAL_COOLDOWN_S,
      bossName: boss ? boss.def.name : null,
      bossHp: boss ? Math.max(0, boss.hp) : 0,
      bossMaxHp: boss ? boss.maxHp : 1,
      interactPrompt: chest ? 'Open chest  [E]' : null,
      fps: Math.round(avgFps),
    });

    useGame.getState().expireToasts();
  }

  // ---------------------------------------------------------------- misc

  requestPointerLock() {
    this.input.requestLock();
  }

  private onResize = () => {
    this.renderer.setSize(window.innerWidth, window.innerHeight, false);
    this.rig.resize(window.innerWidth / window.innerHeight);
  };

  /** Full teardown. Ref-counted asset disposal matters more once GLBs land. */
  dispose() {
    this.stop();
    window.removeEventListener('resize', this.onResize);
    for (const off of this.unsubscribers) off();
    this.unsubscribers.length = 0;

    this.views.dispose();
    this.zoneScene.dispose();
    this.materials.dispose();
    this.floaters.dispose();
    this.input.dispose();
    this.renderer.renderLists.dispose();
    this.renderer.dispose();
    bus.clear();
  }

  /** Dev aid: a rising geometry/texture count between zones is a leak. */
  memoryReport() {
    return this.renderer.info.memory;
  }
}

function getWorldPalette(worldId: string) {
  return getWorld(worldId).palette;
}
