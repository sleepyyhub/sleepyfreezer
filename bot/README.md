# sleepyfreezer-bot

Discord-Bot mit drei umschaltbaren KI-Persönlichkeiten, angetrieben von OpenRouter.

- **Node.js** ≥ 18.17 (`fetch` muss global sein)
- **discord.js** v14
- **OpenRouter**, OpenAI-kompatible `/chat/completions`

## Persönlichkeiten

| Key | Wer | Ton |
|-----|-----|-----|
| `asya` | 🌙 Asya | warm, verspielt, neckt gern |
| `osman` | 🔥 Osman | direkt, trocken, sagt es wie es ist |
| `niki` | 💤 Niki | ruhig, nachdenklich, gute Zuhörerin |

## Commands

| Command | Wirkung |
|---------|---------|
| `/personality name:asya\|osman\|niki` | Wechselt die Persönlichkeit für den ganzen Server |
| `/who` | Zeigt, wer gerade aktiv ist |
| `/reset` | Leert den Gesprächsverlauf des Channels |
| `/exportuser user:@wer` | Exportiert alle Nachrichten eines Users als Datei |

Angesprochen wird der Bot per **@Erwähnung** oder indem man auf eine seiner
Nachrichten **antwortet**.

## Setup

1. Bot anlegen auf https://discord.com/developers/applications
   - Tab **Bot** → Token kopieren
   - Tab **Bot** → **Message Content Intent** einschalten (sonst liest er nichts)
   - Tab **OAuth2 → URL Generator** → Scopes `bot` + `applications.commands`,
     Permissions `Send Messages`, `Read Message History`, `Add Reactions`
2. OpenRouter-Key holen: https://openrouter.ai/keys
3. Konfigurieren und starten:

```bash
cd bot
cp .env.example .env      # Token, Client-ID, Guild-ID und OpenRouter-Key eintragen
npm install
npm run deploy            # Slash-Commands registrieren (einmalig / nach Änderungen)
npm start
```

## `/exportuser`

```
/exportuser user:@niki format:plain channel:#general max:50000
```

| Option | Bedeutung |
|--------|-----------|
| `user` | **Pflicht.** Wessen Nachrichten exportiert werden |
| `format` | `json` (Standard, alles inkl. Metadaten), `txt` (lesbar mit Zeitstempel), `plain` (nur Text, eine Nachricht pro Zeile) |
| `channel` | Nur einen Channel durchsuchen — deutlich schneller |
| `max` | Obergrenze durchsuchter Nachrichten, Standard 50 000 |

Die Antwort ist ephemeral (nur du siehst sie) und der Command ist auf
`Manage Messages` beschränkt, weil er praktisch die halbe Server-History liest.

**Warum das dauert:** Discord hat keinen Endpunkt "alle Nachrichten von User X".
Der Bot blättert jeden lesbaren Channel plus dessen Threads rückwärts durch,
100 Nachrichten pro Request, und filtert selbst. Bei einem großen Server sind
das Minuten — währenddessen aktualisiert er alle 5 Sekunden den Fortschritt.
Über 9 MB wird die Datei gzip-gepackt, darüber hinaus meldet er, dass du mit
`channel:` oder `max:` eingrenzen musst.

Für Stilvorlagen ist `plain` das richtige Format — reiner Text, kein Rauschen.

## Wie es funktioniert

Jede Persönlichkeit ist ein System-Prompt in `src/personalities/index.js`.
`/personality` schreibt den gewählten Key nach `data/state.json` (überlebt
Neustarts) und leert den Verlauf, damit die neue Persona nicht die Antworten der
alten als eigene liest. Pro Channel bleiben die letzten 20 Nachrichten als
Kontext im RAM, und pro Channel läuft immer nur eine Anfrage gleichzeitig,
damit sich Antworten nicht überholen.

## Persönlichkeit anpassen oder hinzufügen

Alles steckt in `src/personalities/index.js`. Ein neuer Eintrag im
`personalities`-Objekt taucht automatisch als Auswahl in `/personality` auf —
danach einmal `npm run deploy` laufen lassen.

## Deploy auf Render

`render.yaml` liegt im Repo — in Render **New → Blueprint** und das Repo
auswählen, dann werden Service und Env-Var-Felder automatisch angelegt.
Danach im Dashboard unter *Environment* eintragen:

- `DISCORD_TOKEN`
- `DISCORD_CLIENT_ID`
- `DISCORD_GUILD_ID` (optional)
- `OPENROUTER_API_KEY`

Slash-Commands werden beim Start automatisch registriert (`AUTO_DEPLOY_COMMANDS=false`
schaltet das ab).

Zwei Dinge zum Free Tier:

- **Er schläft nach 15 Minuten ohne HTTP-Request ein.** Deswegen läuft ein
  Healthcheck auf `/health`. Häng einen Pinger (UptimeRobot, cron-job.org) alle
  10 Minuten drauf, dann bleibt der Bot online. Dauerhaft sauber ist nur ein
  *Background Worker* — der kostet.
- **Das Dateisystem ist flüchtig.** `data/state.json` ist nach jedem Deploy weg,
  der Bot fällt dann auf die Standard-Persönlichkeit zurück. Für echte Persistenz
  ein Render Disk anhängen oder auf Redis/Postgres umstellen.

## Modell

Default ist `openrouter/ox-alpha`. OpenRouter benennt Alpha-/Cloaked-Modelle
regelmäßig um; wenn der Call mit "model not found" zurückkommt, den aktuellen
Slug von https://openrouter.ai/models holen und `OPENROUTER_MODEL` in der `.env`
setzen. Der Rest des Codes bleibt gleich — jedes OpenRouter-Modell funktioniert.
