# Clovyre

A sleek AI chat workspace powered by **Kimi K3** through the TokenRouter API.

Green, quiet, typographic. No build step, no framework, no CDN scripts — an Express
server that proxies the model and a small ES-module frontend.

## Running it

```bash
npm install
cp .env.example .env      # then paste your TokenRouter key into .env
npm start                 # http://localhost:3000
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `TOKENROUTER_API_KEY` | — | **Required.** Your TokenRouter key. |
| `TOKENROUTER_BASE_URL` | `https://api.tokenrouter.com/v1` | API root. |
| `CLOVYRE_MODEL` | `moonshotai/kimi-k3-free` | Any OpenAI-compatible model id. |
| `PORT` | `3000` | Server port. |

The key stays on the server. The browser only ever talks to `/api/chat`, which
streams the upstream response straight through — it is never exposed to the page.

If you run behind an HTTP proxy, set `HTTPS_PROXY`; Node's `fetch` ignores it by
default, so the server wires it up explicitly.

## Features

**Conversation**
- Token-by-token streaming with a stop button
- Kimi's reasoning stream shown as a collapsible *Thought process* block
- Full markdown: headings, lists, tables, blockquotes, links, and syntax-highlighted code
- Copy or regenerate any reply; edit and resend any message
- Conversations saved locally, grouped by age, full-text searchable (`⌘K`)
- Automatic conversation naming, export to Markdown

**Files**
- Attach text files by picker or drag-and-drop — they ride along as context
- Save any code block to the workspace; download files individually or all at once
- A workspace drawer that previews, copies, re-attaches, or deletes each file

**Agent mode**
- The model gets tools — `plan`, `write_file`, `read_file`, `edit_file`, `list_files`,
  `delete_file` — and loops autonomously until the job is done
- Every step is shown as a live card: the plan, each call, each result, each file produced
- Tools execute **in your browser** against the local workspace. Nothing runs on the server.

**Controls**
- System prompt, temperature, top-p, max output tokens
- Dark and light themes, responsive down to phone width, reduced-motion aware

## Shortcuts

| Key | Action |
| --- | --- |
| `Enter` | Send (configurable) |
| `Shift`+`Enter` | Newline |
| `⌘`/`Ctrl`+`Enter` | Send regardless |
| `⌘`/`Ctrl`+`K` | Search conversations |
| `⌘`/`Ctrl`+`Shift`+`O` | New conversation |
| `Esc` | Close panels |

## Layout

```
server.js          Express server + streaming proxy
public/index.html  markup
public/styles.css  theme, layout, components
public/js/app.js   UI, streaming, agent loop
public/js/agent.js tool definitions + browser-side execution
public/js/store.js localStorage persistence
public/js/markdown.js  markdown renderer + highlighter
```

## Notes

`moonshotai/kimi-k3-free` is a free tier: first tokens can take a minute or two,
and the gateway sometimes drops a connection (the server retries up to three
times). Reasoning tokens count against `max_tokens`, so keep that budget
generous — the 8192 default leaves room to think and still answer.
