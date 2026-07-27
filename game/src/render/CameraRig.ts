import * as THREE from 'three';
import type { Terrain } from '@/sim/terrain';

/**
 * Third-person orbit with a spring arm. Chosen over fixed isometric because
 * dodge-with-i-frames combat needs telegraphs readable toward the camera.
 */
export class CameraRig {
  readonly camera: THREE.PerspectiveCamera;
  yaw = 0;
  pitch = 0.42;
  distance = 8.5;

  private targetPos = new THREE.Vector3();
  private currentPos = new THREE.Vector3();
  private lookAt = new THREE.Vector3();
  private shakeAmount = 0;
  private shakeDecay = 6;

  private readonly minPitch = -0.15;
  private readonly maxPitch = 1.25;
  private readonly minDistance = 2.2;

  constructor(aspect: number, private terrain: Terrain) {
    this.camera = new THREE.PerspectiveCamera(58, aspect, 0.1, 400);
    this.currentPos.set(0, 8, 10);
  }

  orbit(dx: number, dy: number) {
    this.yaw -= dx * 0.0032;
    this.pitch = THREE.MathUtils.clamp(this.pitch + dy * 0.0026, this.minPitch, this.maxPitch);
  }

  zoom(delta: number) {
    this.distance = THREE.MathUtils.clamp(this.distance + delta * 0.004, 4, 16);
  }

  shake(amount: number) {
    this.shakeAmount = Math.min(0.45, this.shakeAmount + amount);
  }

  update(dt: number, target: THREE.Vector3, lockOnTarget: THREE.Vector3 | null) {
    // Aim at chest height, not the feet — otherwise the horizon sits too high.
    this.targetPos.copy(target).add(new THREE.Vector3(0, 1.5, 0));

    if (lockOnTarget) {
      // Soft lock: bias camera yaw toward the target rather than snapping,
      // so the player keeps authority over the camera.
      const desired = Math.atan2(
        this.targetPos.x - lockOnTarget.x,
        this.targetPos.z - lockOnTarget.z,
      );
      let diff = desired - this.yaw;
      while (diff > Math.PI) diff -= Math.PI * 2;
      while (diff < -Math.PI) diff += Math.PI * 2;
      this.yaw += diff * (1 - Math.exp(-6 * dt));
    }

    const offset = this.offsetVector(this.distance);
    const desiredPos = this.targetPos.clone().add(offset);

    // Terrain pull-in: sample along the arm and stop short of the ground.
    const clampedDist = this.collideWithTerrain(this.targetPos, offset);
    if (clampedDist < this.distance) {
      desiredPos.copy(this.targetPos).add(this.offsetVector(clampedDist));
    }

    // Frame-rate independent damping. A fixed per-frame lerp would make the
    // camera feel different at 30fps and 144fps.
    const k = 1 - Math.exp(-14 * dt);
    this.currentPos.lerp(desiredPos, k);

    // Never let the camera end up under the terrain.
    const groundY = this.terrain.heightAt(this.currentPos.x, this.currentPos.z) + 0.6;
    if (this.currentPos.y < groundY) this.currentPos.y = groundY;

    this.camera.position.copy(this.currentPos);

    if (this.shakeAmount > 0.001) {
      this.camera.position.x += (Math.random() - 0.5) * this.shakeAmount;
      this.camera.position.y += (Math.random() - 0.5) * this.shakeAmount;
      this.shakeAmount *= Math.exp(-this.shakeDecay * dt);
    }

    this.lookAt.lerp(this.targetPos, k);
    this.camera.lookAt(this.lookAt);
  }

  private offsetVector(dist: number): THREE.Vector3 {
    const cp = Math.cos(this.pitch);
    return new THREE.Vector3(
      Math.sin(this.yaw) * cp * dist,
      Math.sin(this.pitch) * dist,
      Math.cos(this.yaw) * cp * dist,
    );
  }

  /** Marches the arm outward and stops at the first sample below terrain. */
  private collideWithTerrain(origin: THREE.Vector3, offset: THREE.Vector3): number {
    const steps = 8;
    const dir = offset.clone().normalize();
    const len = offset.length();
    for (let i = 1; i <= steps; i++) {
      const d = (i / steps) * len;
      const px = origin.x + dir.x * d;
      const py = origin.y + dir.y * d;
      const pz = origin.z + dir.z * d;
      if (py < this.terrain.heightAt(px, pz) + 0.5) {
        return Math.max(this.minDistance, d - 0.4);
      }
    }
    return len;
  }

  /** Converts WASD into world-space direction relative to where you're looking. */
  worldDirection(inputX: number, inputZ: number): { x: number; z: number } {
    const sin = Math.sin(this.yaw);
    const cos = Math.cos(this.yaw);
    // Camera looks from +offset toward the player, so forward is -offset.
    return {
      x: -inputZ * sin + inputX * cos,
      z: -inputZ * cos - inputX * sin,
    };
  }

  resize(aspect: number) {
    this.camera.aspect = aspect;
    this.camera.updateProjectionMatrix();
  }
}
