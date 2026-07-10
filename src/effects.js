import * as THREE from 'three';

// Kurzlebige 3D-Effekte: Treffer-Funken, Level-Up-Ring
export class Effects {
  constructor(scene) {
    this.scene = scene;
    this.items = [];
  }

  hitSpark(pos) {
    const mat = new THREE.MeshBasicMaterial({
      color: 0xffe066,
      transparent: true,
      opacity: 1,
    });
    const mesh = new THREE.Mesh(new THREE.IcosahedronGeometry(0.22, 0), mat);
    mesh.position.copy(pos);
    mesh.rotation.set(Math.random() * 3, Math.random() * 3, 0);
    this.scene.add(mesh);
    this.items.push({ mesh, life: 0, max: 0.2, kind: 'spark' });
  }

  levelUpRing(pos) {
    const mat = new THREE.MeshBasicMaterial({
      color: 0xffd43b,
      transparent: true,
      opacity: 0.9,
      side: THREE.DoubleSide,
    });
    const mesh = new THREE.Mesh(new THREE.TorusGeometry(0.8, 0.07, 8, 32), mat);
    mesh.position.set(pos.x, 0.15, pos.z);
    mesh.rotation.x = -Math.PI / 2;
    this.scene.add(mesh);
    this.items.push({ mesh, life: 0, max: 0.8, kind: 'ring' });
  }

  update(dt) {
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it = this.items[i];
      it.life += dt;
      const k = it.life / it.max;

      if (k >= 1) {
        this.scene.remove(it.mesh);
        it.mesh.geometry.dispose();
        it.mesh.material.dispose();
        this.items.splice(i, 1);
        continue;
      }

      if (it.kind === 'spark') {
        it.mesh.scale.setScalar(1 + k * 2.2);
        it.mesh.material.opacity = 1 - k;
      } else if (it.kind === 'ring') {
        it.mesh.scale.setScalar(1 + k * 4);
        it.mesh.material.opacity = 0.9 * (1 - k);
      }
    }
  }
}
