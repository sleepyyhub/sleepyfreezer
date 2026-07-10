// Tastatur-Eingaben (WASD, Shift, ...)
export class Input {
  constructor() {
    this.keys = new Set();
    this._attackQueued = false;
    window.addEventListener('keydown', (e) => {
      this.keys.add(e.code);
      if (e.code === 'Space') {
        e.preventDefault();
        this._attackQueued = true;
      }
    });
    window.addEventListener('keyup', (e) => this.keys.delete(e.code));
    window.addEventListener('blur', () => this.keys.clear());
  }

  queueAttack() {
    this._attackQueued = true;
  }

  consumeAttack() {
    const queued = this._attackQueued;
    this._attackQueued = false;
    return queued;
  }

  down(code) {
    return this.keys.has(code);
  }

  // -1..1 auf beiden Achsen (x = rechts/links, z = vor/zurück)
  get axis() {
    const x = (this.down('KeyD') ? 1 : 0) - (this.down('KeyA') ? 1 : 0);
    const z = (this.down('KeyW') ? 1 : 0) - (this.down('KeyS') ? 1 : 0);
    return { x, z };
  }

  get sprint() {
    return this.down('ShiftLeft') || this.down('ShiftRight');
  }
}
