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

    domElement.addEventListener('contextmenu', (e) => e.preventDefault());
    domElement.addEventListener('pointerdown', (e) => {
      this._dragging = true;
      domElement.setPointerCapture(e.pointerId);
    });
    domElement.addEventListener('pointerup', () => (this._dragging = false));
    domElement.addEventListener('pointermove', (e) => {
      if (!this._dragging) return;
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
    this.camera.lookAt(this._target);
  }
}
