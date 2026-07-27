import * as THREE from 'three';

interface Floater {
  el: HTMLDivElement;
  x: number;
  y: number;
  z: number;
  life: number;
  maxLife: number;
  driftX: number;
}

/**
 * Damage numbers as pooled DOM nodes projected from world space. Pooled
 * because allocating an element per hit is a guaranteed GC stutter during a
 * boss fight, and DOM text beats an SDF atlas for this at zero cost.
 */
export class FloatingText {
  private pool: HTMLDivElement[] = [];
  private active: Floater[] = [];
  private container: HTMLDivElement;
  private projected = new THREE.Vector3();

  constructor(parent: HTMLElement, poolSize = 48) {
    this.container = document.createElement('div');
    this.container.style.cssText =
      'position:absolute;inset:0;pointer-events:none;overflow:hidden;';
    parent.appendChild(this.container);

    for (let i = 0; i < poolSize; i++) {
      const el = document.createElement('div');
      el.style.cssText =
        'position:absolute;font-weight:800;will-change:transform,opacity;' +
        'text-shadow:0 2px 4px rgba(0,0,0,.85);white-space:nowrap;' +
        'transform:translate(-50%,-50%);opacity:0;';
      this.container.appendChild(el);
      this.pool.push(el);
    }
  }

  spawn(
    text: string,
    at: { x: number; y: number; z: number },
    opts: { color?: string; size?: number; life?: number } = {},
  ) {
    const el = this.pool.pop();
    // Silently drop the overflow rather than stuttering — nobody can read 48
    // simultaneous numbers anyway.
    if (!el) return;

    el.textContent = text;
    el.style.color = opts.color ?? '#ffffff';
    el.style.fontSize = `${opts.size ?? 20}px`;
    el.style.opacity = '1';

    this.active.push({
      el,
      x: at.x,
      y: at.y,
      z: at.z,
      life: 0,
      maxLife: opts.life ?? 0.9,
      driftX: (Math.random() - 0.5) * 1.2,
    });
  }

  update(dt: number, camera: THREE.Camera, width: number, height: number) {
    for (let i = this.active.length - 1; i >= 0; i--) {
      const f = this.active[i];
      f.life += dt;

      if (f.life >= f.maxLife) {
        f.el.style.opacity = '0';
        this.pool.push(f.el);
        this.active.splice(i, 1);
        continue;
      }

      const t = f.life / f.maxLife;
      // Rise fast then slow, drift sideways: reads as a pop rather than a slide.
      const rise = 1.4 * Math.sqrt(t);

      this.projected.set(f.x + f.driftX * t, f.y + rise, f.z).project(camera);

      // Behind the camera: hide rather than mirroring it onto the screen.
      if (this.projected.z > 1) {
        f.el.style.opacity = '0';
        continue;
      }

      const sx = (this.projected.x * 0.5 + 0.5) * width;
      const sy = (-this.projected.y * 0.5 + 0.5) * height;
      const scale = 1 + (1 - t) * 0.35;

      f.el.style.transform = `translate(-50%,-50%) translate(${sx}px,${sy}px) scale(${scale})`;
      f.el.style.opacity = String(t > 0.65 ? 1 - (t - 0.65) / 0.35 : 1);
    }
  }

  dispose() {
    this.container.remove();
    this.pool.length = 0;
    this.active.length = 0;
  }
}
