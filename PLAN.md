# 3D RPG — Projektplan

## Tech-Stack
- **Three.js** — 3D-Rendering im Browser
- **Vite** — Dev-Server & Build
- **JavaScript (ES Modules)** — kein Extra-Setup nötig
- Läuft überall ohne Installation (nur Browser)

## Spielkonzept (Startversion)
Ein Third-Person Action-RPG in einer kleinen 3D-Welt:
- Spielerfigur, die man mit WASD bewegt (Kamera folgt)
- Begehbare Welt mit Boden, Hindernissen, Deko
- Gegner, die man bekämpfen kann
- Lebenspunkte (HP), einfache Kampfmechanik
- Erfahrungspunkte (XP) & Level-Aufstieg
- Einfaches Inventar / Items zum Aufsammeln

## Umsetzung in Etappen

### Etappe 1 — Grundgerüst ✅
- [x] Projekt-Setup (Vite, Three.js)
- [x] Szene, Kamera, Licht (Cel-Shading/Toon-Look), Render-Loop

### Etappe 2 — Spieler & Steuerung ✅
- [x] Spielerfigur "Kaito" (Low-Poly-Schwertkämpfer mit Katana)
- [x] WASD-Bewegung + Sprint, Lauf-/Idle-Animation
- [x] Third-Person-Kamera (Maus drehen, Mausrad zoomen)
- [x] Kollision mit Hindernissen + Weltgrenze

### Etappe 3 — Welt ✅ (erste Version)
- [x] Karte mit Sakura-Bäumen, Torii-Tor, Felsen, Blumen, Wolken
- [ ] Mehr Zonen/Gebiete (später)

### Etappe 4 — Kampf ✅
- [x] Anime-Devils (2 Stufen: lila normal, rot groß) mit KI:
      umherstreifen → verfolgen → Angriff mit Telegraph → zurück zum Revier
- [x] Schwertangriff (Klick/Leertaste) mit Lunge, Treffer-Funken, Rückstoß
- [x] HP-System beidseitig, Schadenszahlen, Kamera-Shake, Rot-Vignette
- [x] Tod & Respawn (Spieler am Spawn, Gegner nach 12s im Revier)

### Etappe 5 — RPG-Systeme
- [x] XP & Level-Ups (mehr HP & Schaden, Voll-Heilung, Gold-Ring-Effekt)
- [x] HUD: HP-Balken, XP-Leiste, Level, Gegner-HP-Balken
- [ ] Items aufsammeln & einfaches Inventar
- [ ] Charakterauswahl (Kettensägen-Kämpfer, Grimoire-Magier)

### Etappe 6 — Feinschliff
- Sound, Menü/Startbildschirm
- Speicherstand (localStorage)

## Steuerung (geplant)
- **WASD** — Bewegen
- **Maus** — Kamera drehen
- **Linksklick / Leertaste** — Angriff
- **E** — Interagieren / Aufsammeln

## Getroffene Entscheidungen
- **Stil:** Anime-inspiriert, Low-Poly & bunt
- **Perspektive:** Third-Person (Kamera folgt der Figur)
- **Setting:** Anime-RPG mit mehreren spielbaren Charakter-Archetypen,
  angelehnt an bekannte Animes (eigene Designs, kein 1:1-Kopieren):
  - *Kettensägen-Kämpfer* (CSM-Vibe) — Nahkampf, hoher Schaden
  - *Grimoire-Magier* (Black-Clover-Vibe) — Fernkampf-Zauber
  - *Schwertkämpfer* — ausgewogen, schnell
- Gegner als Anime-Style Monster/Devils

## Rechtlicher Hinweis
Eigene, anime-inspirierte Designs & Namen — keine geschützten
Original-Charaktere, damit das Projekt frei nutzbar bleibt.
</content>
