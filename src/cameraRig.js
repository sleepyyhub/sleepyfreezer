import * as THREE from 'three';

// Third-Person-Kamera: kreist um den Spieler, Maus ziehen = drehen, Rad = Zoom
export class CameraRig {
  constructor(camera, domElement) {
    this.camera = camera;
    this.yaw = 0; // 0 = Kamera hinter dem Spieler (Spieler schaut Richtung -Z)
    this.pitch = 0.32;
    this.dist = 7;

    this._target = new THREE.Vector3();
    this._desired = new THREE.Vector3();
    this._dragging = false;
    this._shake = 0;
    this._moved = 0;
    this._downTime = 0;
    this.onTap = null; // kurzer Klick ohne Ziehen => Angriff

    domElement.addEventListener('contextmenu', (e) => e.preventDefault());
    domElement.addEventListener('pointerdown', (e) => {
      this._dragging = true;
      this._moved = 0;
      this._downTime = performance.now();
      domElement.setPointerCapture(e.pointerId);
    });
    domElement.addEventListener('pointerup', () => {
      this._dragging = false;
      if (this._moved < 6 && performance.now() - this._downTime < 350) {
        this.onTap?.();
      }
    });
    domElement.addEventListener('pointermove', (e) => {
      if (!this._dragging) return;
      this._moved += Math.abs(e.movementX) + Math.abs(e.movementY);
      this.yaw -= e.movementX * 0.005;
      this.pitch = THREE.MathUtils.clamp(this.pitch + e.movementY * 0.004, -0.1, 1.2);
    });
    domElement.addEventListener(
      'wheel',
      (e) => {
        e.preventDefault();
        this.dist = THREE.MathUtils.clamp(this.dist + Math.sign(e.deltaY), 4, 14);
      },
      { passive: false }
    );
  }

  addShake(amount) {
    this._shake = Math.max(this._shake, amount);
  }

  update(dt, targetPos) {
    this._target.copy(targetPos);
    this._target.y += 1.6; // auf Kopfhöhe schauen

    const cp = Math.cos(this.pitch);
    this._desired.set(
      this._target.x + Math.sin(this.yaw) * cp * this.dist,
      this._target.y + Math.sin(this.pitch) * this.dist,
      this._target.z + Math.cos(this.yaw) * cp * this.dist
    );

    // weiches Nachziehen
    const t = 1 - Math.pow(0.0001, dt);
    this.camera.position.lerp(this._desired, t);

    // Kamera-Wackeln bei Treffern
    if (this._shake > 0) {
      this._shake = Math.max(0, this._shake - dt * 1.6);
      const s = this._shake * 0.35;
      this.camera.position.x += (Math.random() - 0.5) * s;
      this.camera.position.y += (Math.random() - 0.5) * s;
    }

    this.camera.lookAt(this._target);
  }
}
