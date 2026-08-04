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

## Run it

```bash
cp server/.env.example server/.env   # set DATABASE_URL and OPENROUTER_API_KEY
npm run setup                        # installs both halves, migrates, seeds
npm start                            # http://localhost:4000
```

`npm start` builds the frontend and serves it from the API process, so the whole
app runs on one origin at `http://localhost:4000` — no CORS, and the session
cookie stays first-party.

For frontend work with hot reload, run the two halves separately instead:

```bash
npm run dev:api    # http://localhost:4000
npm run dev:web    # http://localhost:5173
```

In that mode the frontend talks to `http://localhost:4000` by default; override
with `VITE_API_URL` in `web/.env`.

## Accounts

Email + username + password sign-in works out of the box, with no email
confirmation — addresses are stored as given and never verified, so treat them
as labels rather than proof of anything. Passwords are bcrypt-hashed. Sign in
with either the email or the username.

Google and Discord sign-in also work, but only once you add credentials to
`server/.env`; the sign-in screen hides those buttons until you do.

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

## Deploying

The app is one Node process plus a Postgres database. Both hosts below work on
their free tiers, with one caveat noted at the end.

**Build command:** `npm run build`
**Start command:** `npm start`

`npm start` applies the schema, seeds the characters, and serves the API and the
frontend together on the port the host provides. Both steps are idempotent, so
redeploys are safe.

### Render

A blueprint is included, so it creates the database and the service together:

1. Push this repo to GitHub.
2. Render dashboard > **New** > **Blueprint**, pick the repo. It reads
   `render.yaml` and creates `clovyre-db` and the `clovyre` web service.
3. After the first deploy, open the service > **Environment** and set:
   - `OPENROUTER_API_KEY` — your key
   - `CLIENT_URL` — the service's own URL, e.g. `https://clovyre.onrender.com`
4. Redeploy.

`JWT_SECRET` and `CRON_SECRET` are generated by Render; read `CRON_SECRET` from
the Environment tab, you need it for the scheduler.

### Railway

Railway has no blueprint here, so wire it up by hand:

1. **New Project** > **Deploy from GitHub repo**.
2. Add a **PostgreSQL** database to the project.
3. On the app service, **Settings** > set build command `npm run build` and
   start command `npm start`.
4. **Variables** on the app service:
   - `DATABASE_URL` = `${{Postgres.DATABASE_URL}}` (Railway substitutes it)
   - `NODE_ENV` = `production`
   - `OPENROUTER_API_KEY` = your key
   - `JWT_SECRET` = a long random string
   - `CRON_SECRET` = another long random string
5. **Settings** > **Networking** > **Generate Domain**, then set `CLIENT_URL` to
   that domain and redeploy.

### The scheduled ping

Characters only message first if something calls the sweep:

```
POST https://<your-app>/api/cron/proactive
Header: x-cron-secret: <your CRON_SECRET>
```

**Every 30 minutes.** The endpoint is cheap and idempotent — it checks who is
actually due and usually does nothing, so calling it often is fine, and calling
it rarely just means characters reach out late. Anything from 15 to 60 minutes is
reasonable; below 15 is wasted work, above 60 makes the 2–6 hour quiet window
inaccurate.

Three ways to schedule it, cheapest first:

- **GitHub Actions** — `.github/workflows/proactive-cron.yml` is already in this
  repo. Add two repository secrets under Settings > Secrets and variables >
  Actions: `APP_URL` (no trailing slash) and `CRON_SECRET`. Free on public repos.
  Use the workflow's **Run workflow** button once to check it works.
- **cron-job.org** — free, no account tie-in. Add the URL, method POST, the
  custom header, and a 30-minute interval.
- **The host's own scheduler** — Render Cron Jobs and Railway cron are both paid
  features, so only worth it if you are already on a paid plan.

### Free-tier caveat

Render's free web services sleep after 15 minutes of inactivity and take roughly
a minute to wake. The scheduled ping wakes the app, runs the sweep, and lets it
sleep again, so proactive messages still work — but a visitor hitting a sleeping
app waits for that cold start. Railway does not sleep, but bills against a
monthly credit instead. Neither is a problem for testing; pick a paid tier before
real users arrive.

## Tests

```bash
npm test                     # thought-parser suite
```

Covers thought extraction across every response shape the free models produce,
including regressions captured from real output.
