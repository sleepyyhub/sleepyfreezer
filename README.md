# Clovyre

AI character chat — talk to characters one-on-one or put them in a group and let
them talk to each other. Every reply opens with the character's inner monologue,
characters mirror whatever language you write in, and they will message you first
when a conversation has gone quiet.

```
web/      Vite + React frontend
server/   Express + Prisma API
shared/   brand tokens used by both
```

## Requirements

- Node 18+
- PostgreSQL 14+
- An [OpenRouter](https://openrouter.ai) API key (free tier is enough)
- Optional: Google and/or Discord OAuth credentials, and a Pusher app

## Setup

```bash
# 1. API
cd server
npm install
cp .env.example .env          # fill in DATABASE_URL and OPENROUTER_API_KEY
npx prisma db push
npm run db:seed               # creates the five Nakano sisters
npm run dev                   # http://localhost:4000

# 2. Frontend
cd ../web
npm install
npm run dev                   # http://localhost:5173
```

The frontend talks to `http://localhost:4000` by default. Point it elsewhere with
`VITE_API_URL` in `web/.env`.

## Models

All free tier, tried in order — a rate-limited model falls through to the next:

| Model | Role |
|---|---|
| `inclusionai/ling-3.0-flash:free` | primary |
| `google/gemma-4-31b-it:free` | fallback |
| `nvidia/nemotron-3-nano-30b-a3b:free` | fallback |
| `openai/gpt-oss-20b:free` | last resort |

Override with `OPENROUTER_MODELS` (comma-separated) in `server/.env`.

Ling leads because it was measurably the best of the free options for this job:
2–4 second replies, it holds a character's voice and verbal tics, it mirrors the
user's language, it gets in-world facts right, and it stays in character in
mature mode. Temperature is 0.7 rather than the vendor default of 1.0 —
characters drift out of voice at high temperature.

NVIDIA NIM's `thinkingmachines/inkling` was evaluated and rejected: on the free
tier a single reply took over five minutes. The Nemotron reasoning models leak
their planning prose into the response body, which is why the parser defends
against it.

## How it works

**Character prompts.** `server/src/ai/prompt.js` assembles the system prompt from
a character's `personality`, `lore`, and `speakingStyle`. Sample lines in
`speakingStyle` do more for believability than any number of adjectives —
`server/src/seed/characters.js` shows the shape.

**Inner thoughts.** Characters are told to open every reply with
`*Name thinks: ...*`. `server/src/ai/parse.js` splits that off from the spoken
text, and also handles `<think>` tags, reasoning returned in a separate field,
stray thought lines mid-message, and planning prose that leaks out of the
reasoning channel. Run `node test/parse.test.js` to exercise those cases.

**Groups.** When you send a message, a low-temperature "director" call picks who
answers — except that anyone addressed by name always answers, which is enforced
in code rather than left to the model. After the first reply there is a 40%
chance another character reacts to it, chained up to three times, so the cast
talks among themselves.

**Reaching out first.** `POST /api/cron/proactive` (guarded by `CRON_SECRET`)
sweeps for conversations that have been quiet for a randomised 2–6 hours and has
one character send an unprompted message. Run it every 30–60 minutes. The
randomness matters: a character who always messages at exactly four hours reads
as a cron job rather than a person.

**Mature content.** Off by default, per-user. A character must also be flagged
`nsfwAllowed`, and those characters are hidden entirely from users who have not
opted in.

**Realtime is optional.** Sending a message returns the replies over HTTP, so the
app works fully without Pusher. Configuring it adds character-to-character
messages appearing one at a time, and proactive messages arriving without a
refresh.

## Tests

```bash
cd server && node test/parse.test.js
```

Covers thought extraction across every response shape the free models produce,
including regressions captured from real output.
