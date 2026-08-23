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

## Modell

Default ist `openrouter/ox-alpha`. OpenRouter benennt Alpha-/Cloaked-Modelle
regelmäßig um; wenn der Call mit "model not found" zurückkommt, den aktuellen
Slug von https://openrouter.ai/models holen und `OPENROUTER_MODEL` in der `.env`
setzen. Der Rest des Codes bleibt gleich — jedes OpenRouter-Modell funktioniert.
