import type { InputIntent } from '@/sim/World';

/**
 * Collects raw device state and produces one intent struct per sim tick.
 * Edge-triggered actions (attack, dodge, interact) are latched here and
 * cleared on read, so a press can never be missed between ticks.
 */
export class Input {
  private keys = new Set<string>();
  private latched = new Set<string>();
  private pointerLocked = false;

  mouseDX = 0;
  mouseDY = 0;
  wheelDelta = 0;

  /** UI panels swallow gameplay input while open. */
  enabled = true;

  private listeners: (() => void)[] = [];

  constructor(private canvas: HTMLCanvasElement) {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.repeat) return;
      const code = e.code;
      this.keys.add(code);
      this.latched.add(code);
      // Space scrolls the page and F-keys do worse; claim the ones we use.
      if (['Space', 'Tab', 'KeyE', 'KeyQ'].includes(code)) e.preventDefault();
    };
    const onKeyUp = (e: KeyboardEvent) => this.keys.delete(e.code);

    const onMouseDown = (e: MouseEvent) => {
      if (e.button === 0) {
        this.keys.add('Mouse0');
        this.latched.add('Mouse0');
      }
      if (e.button === 2) {
        this.keys.add('Mouse2');
        this.latched.add('Mouse2');
      }
    };
    const onMouseUp = (e: MouseEvent) => {
      if (e.button === 0) this.keys.delete('Mouse0');
      if (e.button === 2) this.keys.delete('Mouse2');
    };

    const onMouseMove = (e: MouseEvent) => {
      if (this.pointerLocked) {
        this.mouseDX += e.movementX;
        this.mouseDY += e.movementY;
      }
    };

    const onWheel = (e: WheelEvent) => {
      this.wheelDelta += e.deltaY;
      e.preventDefault();
    };

    const onLockChange = () => {
      this.pointerLocked = document.pointerLockElement === this.canvas;
    };

    const onContext = (e: Event) => e.preventDefault();

    // Losing focus mid-key otherwise leaves the player running forever.
    const onBlur = () => this.keys.clear();

    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    window.addEventListener('mousedown', onMouseDown);
    window.addEventListener('mouseup', onMouseUp);
    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('blur', onBlur);
    document.addEventListener('pointerlockchange', onLockChange);
    canvas.addEventListener('wheel', onWheel, { passive: false });
    canvas.addEventListener('contextmenu', onContext);

    this.listeners.push(() => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
      window.removeEventListener('mousedown', onMouseDown);
      window.removeEventListener('mouseup', onMouseUp);
      window.removeEventListener('mousemove', onMouseMove);
      window.removeEventListener('blur', onBlur);
      document.removeEventListener('pointerlockchange', onLockChange);
      canvas.removeEventListener('wheel', onWheel);
      canvas.removeEventListener('contextmenu', onContext);
    });
  }

  requestLock() {
    if (!this.pointerLocked) void this.canvas.requestPointerLock();
  }

  releaseLock() {
    if (this.pointerLocked) document.exitPointerLock();
  }

  get isLocked() {
    return this.pointerLocked;
  }

  isDown(code: string): boolean {
    return this.keys.has(code);
  }

  /** True once per press. */
  consume(code: string): boolean {
    if (!this.latched.has(code)) return false;
    this.latched.delete(code);
    return true;
  }

  /**
   * Builds the intent for one sim tick. `toWorld` rotates raw WASD into
   * camera-relative world space.
   */
  snapshot(toWorld: (x: number, z: number) => { x: number; z: number }): InputIntent {
    if (!this.enabled) {
      this.latched.clear();
      return {
        moveX: 0,
        moveZ: 0,
        light: false,
        heavy: false,
        dodge: false,
        special: false,
        interact: false,
        lockOn: false,
      };
    }

    let ix = 0;
    let iz = 0;
    if (this.isDown('KeyW') || this.isDown('ArrowUp')) iz += 1;
    if (this.isDown('KeyS') || this.isDown('ArrowDown')) iz -= 1;
    if (this.isDown('KeyA') || this.isDown('ArrowLeft')) ix -= 1;
    if (this.isDown('KeyD') || this.isDown('ArrowRight')) ix += 1;

    const dir = toWorld(ix, iz);

    return {
      moveX: dir.x,
      moveZ: dir.z,
      light: this.consume('Mouse0'),
      heavy: this.consume('Mouse2') || this.consume('KeyF'),
      dodge: this.consume('Space'),
      special: this.consume('KeyQ'),
      interact: this.consume('KeyE'),
      lockOn: this.consume('KeyT'),
    };
  }

  /** Mouse deltas are accumulated between frames and drained by the camera. */
  drainMouse(): { dx: number; dy: number; wheel: number } {
    const out = { dx: this.mouseDX, dy: this.mouseDY, wheel: this.wheelDelta };
    this.mouseDX = 0;
    this.mouseDY = 0;
    this.wheelDelta = 0;
    return out;
  }

  dispose() {
    for (const off of this.listeners) off();
    this.listeners.length = 0;
  }
}
