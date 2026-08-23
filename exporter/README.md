# Discord Message Exporter

Eigenständige Kommandozeilen-App, die alle Nachrichten eines Users aus einem
Server in eine Datei schreibt. Läuft lokal auf deinem Rechner — nichts muss
gehostet werden, nichts läuft dauerhaft.

**Node.js ≥ 18.17, null Dependencies.** Kein `npm install` nötig.

## Start

```bash
cd exporter
node src/index.js
```

Die App fragt dich der Reihe nach nach Token, Server, User-ID und Format.
Wer nicht tippen will, hinterlegt den Token einmalig:

```bash
cp .env.example .env    # DISCORD_BOT_TOKEN oder DISCORD_USER_TOKEN eintragen
```

## Nicht-interaktiv

```bash
node src/index.js --guild 123456789 --user 987654321 --format plain
```

| Flag | Bedeutung |
|------|-----------|
| `--guild` | Server-ID oder exakter Name. Ohne das kommt eine Auswahlliste |
| `--user` | User-ID des Ziels (`<@123>` wird auch akzeptiert) |
| `--format` | `plain`, `json` oder `txt` |
| `--channel` | Nur diesen Channel durchsuchen |
| `--max` | Obergrenze durchsuchter Nachrichten, Standard 100 000 |
| `--crawl` | Search-API überspringen und stur alles durchblättern |
| `--out` | Zielordner, Standard `exports/` |

## Formate

| Format | Inhalt |
|--------|--------|
| `plain` | Nur der Text, eine Nachricht pro Zeile. Die beste Stilvorlage |
| `json` | Alles: IDs, Zeitstempel, Channel, Anhänge, Reply-Bezüge, Statistik |
| `txt` | Lesbar: `[2026-08-23 12:00:00] #general: Nachricht` |

Nachrichten sind chronologisch sortiert, älteste zuerst — über die
Snowflake-ID, nicht über die Reihenfolge, in der Discord sie ausspuckt.

## Bot-Token oder Account-Token

Die App akzeptiert beide, und der Unterschied ist groß:

|  | Bot-Token | Account-Token |
|--|-----------|---------------|
| Application muss im Server sein | ja | nein |
| Methode | jeden Channel durchblättern | Search-API |
| Tempo bei 100k Nachrichten | Minuten | Sekunden |
| Discord-ToS | erlaubt | **Selfbotting, kann den Account kosten** |

Den Bot-Weg bekommst du über https://discord.com/developers/applications →
*Bot* → Token, danach die Application mit `Read Message History` in den Server
einladen. Der Account-Weg ist schneller und braucht niemanden im Server, ist
aber gegen die Regeln — deine Entscheidung, ich sag es nur einmal.

Fällt die Search-API aus (Rechte, Index noch nicht gebaut), wechselt die App
automatisch aufs Durchblättern.

## Wie es funktioniert

Discord hat keinen Endpunkt "alle Nachrichten von User X". Zwei Wege führen
trotzdem hin:

- **Search** (`/guilds/{id}/messages/search?author_id=`) fragt direkt den
  Suchindex — 25 Treffer pro Seite, dafür bei etwa 5000 Ergebnissen gedeckelt.
  Nur mit Account-Token erreichbar.
- **Crawl** blättert jeden lesbaren Channel plus aktive und archivierte Threads
  rückwärts durch, 100 Nachrichten pro Request, und filtert lokal. Langsam,
  aber vollständig und regelkonform.

Rate Limits werden in beiden Fällen behandelt: die App liest
`x-ratelimit-remaining` mit und bremst von selbst, bevor Discord sie bremst,
und wiederholt bei 429 nach dem gemeldeten `retry_after`.

## Grenzen

- Channels ohne Leserechte werden übersprungen und am Ende gezählt.
- Der Search-Weg endet bei ~5000 Treffern — für mehr `--crawl` benutzen.
- Gelöschte Nachrichten sind weg, die holt keine API zurück.
