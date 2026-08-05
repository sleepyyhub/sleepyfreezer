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
- An API key from at least one provider — [Groq](https://console.groq.com) is
  the most generous free option and needs no card
- Optional: Google and/or Discord OAuth credentials, and a Pusher app

## Run it

```bash
cp server/.env.example server/.env   # set DATABASE_URL and one provider key
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

## Models and providers

Free allowances reset daily, so an exhausted provider comes back on its own —
which is the point of the ladder: spread across several and no single one drains.

Providers are OpenAI-compatible and configured in `server/src/ai/providers.js`.
Set a provider's API key to enable it; the ladder spans providers in order, so
when one exhausts its free allowance the next takes over rather than the app
going down. A provider that returns 429 is skipped for 15 minutes — without
that, every message pays the latency of walking dead rungs first.

| Provider | Env key | Free tier | Card? | Notes |
|---|---|---|---|---|
| Novita | `NOVITA_API_KEY` | Ling-3.0-flash at $0/token | yes | The upstream OpenRouter resells Ling from. Returns 403 at a zero balance, so a top-up (min $10) is required even for a zero-priced model. |
| OpenRouter | `OPENROUTER_API_KEY` | 50 req/day, or 1,000 once 10 credits have been bought | no | The cap is per-account across all `:free` models, so listing more of them buys no headroom (20 req/min either way). A paid model on the same key is outside that cap, so `inclusionai/ling-2.6-flash` sits at the end of the list as a fallback — same family as the free model, about $0.01/$0.03 per million tokens. |
| Groq | `GROQ_API_KEY` | ~1,000 req/day per model, 30 req/min | no | Fastest measured. Judge it by the per-model daily cap, not the larger account-wide figure — a group chat spends several requests per message. |
| Cerebras | `CEREBRAS_API_KEY` | ~1M tokens/day | no | Very fast, but the no-card tier is being retired for a credit-based one. |
| Gemini | `GEMINI_API_KEY` | ~1,500 req/day | no | Google's terms allow free-tier prompts to be used for training — a poor fit for private conversations. |
| Mistral | `MISTRAL_API_KEY` | modest | no | |
| NVIDIA | `NVIDIA_API_KEY` | separate allowance | no | Least reliable measured: 503s, 529s, and >70s on larger models. Only the 8B model answered promptly. |
| Cloudflare | `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` | daily allowance | no | The account id goes in the URL, so both are required or the provider is skipped. |
| Hugging Face | `HF_TOKEN` | monthly credits | no | Routes to inference partners. |
| GitHub Models | `GITHUB_MODELS_TOKEN` | tied to your Copilot tier | no | A GitHub personal access token. |
| TokenRouter | `TOKENROUTER_API_KEY` | promotional free models | yes, for paid models | Its `kimi-k3-free` accepted requests and never answered when measured (150s, zero bytes), while a paid model on the same key refused in 2s with a clear quota error. Last in the order. An aggregator also sees the full text of every conversation. |

Order with `AI_PROVIDERS=groq,openrouter`, and override a provider's models with
e.g. `GROQ_MODELS=`.

Cooldowns are per provider *and* model, not per provider: one account can hold a
capped free model and an uncapped paid one, and a 429 on the free one says
nothing about the paid one. A provider that hangs is worse than one that
refuses, so a timeout also starts a cooldown (5 minutes, against 15 for a rate
limit) and the per-request budget is 25 seconds. Measured against a provider that never answered: the first message
cost 78s, the next two 375ms and 318ms.

Ling-3.0-flash leads because it was measurably the best free option for this
job: 2-4 second replies, it holds a character's voice and verbal tics, it
mirrors the user's language, it gets in-world facts right, and it stays in
character in mature mode. Temperature is 0.7 rather than the vendor default of
1.0 — characters drift out of voice at high temperature.

NVIDIA NIM's `thinkingmachines/inkling` was evaluated and rejected: on the free
tier a single reply took over five minutes. The Nemotron reasoning models leak
their planning prose into the response body, which is why the parser defends
against it.

### Avatars

Characters fall back to an initials tile, and a portrait can be drawn on demand
from the character's own personality text — the button is on the character page.

Image models are priced per picture rather than per token, and the gap is wide:
one avatar from `google/gemini-3.1-flash-lite-image` costs about **$0.034**, so a
few dollars of credit buys under a hundred. Generation is therefore an explicit
action, never part of creating a character, and the result is stored on the
character so it is produced exactly once. Redrawing is possible but asks again.

Providers are tried free-first: Cloudflare Workers AI (`CLOUDFLARE_API_TOKEN` +
`CLOUDFLARE_ACCOUNT_ID`, free daily allowance, no card) before OpenRouter. With
neither configured the button is hidden rather than failing — `/api/health`
reports `images: true|false`.

Images are stored in Postgres and served from `/api/characters/:id/avatar` with
a long cache lifetime. There is no object store to point at, and roughly 600KB
per avatar against a hundred-odd avatars is well within a small database.

`MOCK_AI=true` serves canned replies without calling any provider — useful for
front-end work that would otherwise spend a limited daily allowance.

## How it works

**Character prompts.** `server/src/ai/prompt.js` assembles the system prompt from
a character's `personality`, `lore`, and `speakingStyle`. Sample lines in
`speakingStyle` do more for believability than any number of adjectives —
`server/src/seed/characters.js` shows the shape.

**Roleplay action.** Characters narrate physical action in asterisks —
`*steps back*` — which is convention, not markup a reader should see. The
markers are stripped and the action is styled apart from speech, on both sides
of the conversation, since people write action too. Arithmetic like `2 * 3`
is left alone: both ends of an action must sit against a non-space character.

**Memory.** Characters already receive the last 120 messages, so context was
never the missing piece — salience was. A detail from forty messages ago is
technically present and practically invisible, and past the window it is gone.
So every 14 messages a background pass extracts durable facts — where someone
lives, what they do, promises made — and pins them near the top of the system
prompt, written from the character's own point of view. Extraction runs after
the reply is already on its way, and claims its window with a conditional
cursor update so two messages in quick succession cannot extract the same facts
twice.

**Scene illustrations.** A character may end a message with `[scene: ...]`, which
becomes a picture. Off by default (`sceneImagesEnabled`), limited to one every 20
messages, and drawn from the character's stored portrait when they have one so
the scene looks like them. The marker is always stripped from the text whether
or not an image results.

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

**Saved characters.** A bookmark on a card or a character page, backed by a
`SavedCharacter` row rather than component state, and readable back through the
Saved tab. Kept apart from `Conversation` because saving someone for later is
not the same as having talked to them.

**Deleting an account.** `DELETE /api/settings/account`, confirmed by typing the
username or email back — the only proof available for an account that signed in
through Google and has no password stored here. Conversations, groups, messages,
memories, and bookmarks cascade from the user row. Published characters do not:
`creatorId` is `SetNull`, so they survive unattributed rather than disappearing
out of other people's chats.

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

### Proactive messages

The API sweeps for characters who should reach out **every 30 minutes by
itself** — `PROACTIVE_INTERVAL_MINUTES` controls it, and it also sweeps 30
seconds after boot so a host waking from sleep delivers whatever came due while
it was down. Nothing external is required.

`POST /api/cron/proactive` still exists, guarded by `CRON_SECRET`, and is worth
using in two cases: to trigger a sweep by hand while testing, or if you ever run
more than one instance — the internal timer fires per process, so two instances
would sweep twice. Set `PROACTIVE_INTERVAL_MINUTES=0` to disable the timer and
drive sweeps only from the endpoint.

`.github/workflows/proactive-cron.yml` calls that endpoint on a schedule if you
prefer to drive it externally; it needs `APP_URL` and `CRON_SECRET` as repository
secrets. It is not needed with the default setup.

### Free-tier caveat

Render's free web services sleep after 15 minutes of inactivity and take roughly
a minute to wake, and a sleeping process runs no timers. Any uptime pinger
hitting the app URL keeps it awake and the internal scheduler then runs normally
— a plain GET on `/` every 10 minutes is enough, no secret or POST involved.
Without one, proactive messages only go out while somebody is using the app.

Railway does not sleep, but bills against a monthly credit instead. Neither is a
problem for testing; pick a paid tier before real users arrive.

## Tests

```bash
npm test
```

Covers thought extraction across every response shape the free models produce —
including regressions captured from real output — roleplay segmentation, and
sample-line extraction from a speaking-style sheet.

## A note on the interface

Nothing on screen is allowed to be decorative if it looks functional. An
earlier pass had a green presence dot on every character, a follower count
derived as 32% of the message count, a `⌘K` hint bound to nothing, four
settings toggles that lived in `useState` and saved nothing, a bookmark that
toasted "Saved to your library" with no library behind it, a "Featured" badge
on 100% of characters, and attach/image/microphone buttons in the composer
with no upload endpoint anywhere. Those are the details that make software feel
generated, and they are worth auditing for as deliberately as any bug: a
control that lies is worse than a missing feature.

Where a surface was worth keeping, it was made real — the bookmark and account
deletion both became actual endpoints. Where it was not, it was removed.
