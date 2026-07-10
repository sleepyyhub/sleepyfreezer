import * as THREE from 'three';

// HUD-Updates, Schadenszahlen, Bildschirm-Effekte
export class UI {
  constructor() {
    this.hpFill = document.getElementById('hp-fill');
    this.xpFill = document.getElementById('xp-fill');
    this.levelEl = document.getElementById('char-level');
    this.vignette = document.getElementById('vignette');
    this.announceEl = document.getElementById('announce');
    this._announceTimer = null;
    this._v = new THREE.Vector3();
  }

  setHp(cur, max) {
    this.hpFill.style.width = `${Math.max(0, (cur / max) * 100)}%`;
  }

  setXp(cur, next) {
    this.xpFill.style.width = `${Math.min(100, (cur / next) * 100)}%`;
  }

  setLevel(lv) {
    this.levelEl.textContent = `Lv. ${lv}`;
  }

  // Schwebende Schadenszahl an einer Welt-Position
  damageNumber(worldPos, camera, text, cls = '') {
    this._v.copy(worldPos).project(camera);
    if (this._v.z > 1) return; // hinter der Kamera

    const x = (this._v.x * 0.5 + 0.5) * window.innerWidth;
    const y = (-this._v.y * 0.5 + 0.5) * window.innerHeight;

    const el = document.createElement('div');
    el.className = `dmg ${cls}`;
    el.textContent = text;
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
    document.body.appendChild(el);
    setTimeout(() => el.remove(), 850);
  }

  // roter Bildschirmrand, wenn der Spieler Schaden nimmt
  flashVignette() {
    this.vignette.classList.add('show');
    setTimeout(() => this.vignette.classList.remove('show'), 280);
  }

  // große Mittel-Ansage ("LEVEL UP!", "K.O.!")
  announce(text, cls = '') {
    clearTimeout(this._announceTimer);
    this.announceEl.textContent = text;
    this.announceEl.className = `show ${cls}`;
    this._announceTimer = setTimeout(() => {
      this.announceEl.className = '';
    }, 1500);
  }
}
