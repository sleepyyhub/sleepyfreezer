import { renderMarkdown, escapeHtml } from './markdown.js';
import {
  state, save, uid, createChat, deleteChat, touch, groupChats,
  writeFile, deleteFile, guessLanguage, bytes, DEFAULT_SYSTEM_PROMPT,
} from './store.js';
import { AGENT_SYSTEM, TOOLS, runTool, summarizeArgs } from './agent.js';

const $ = (sel) => document.querySelector(sel);
const el = (tag, cls, html) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html != null) n.innerHTML = html;
  return n;
};

const ui = {
  messages: $('#messages'), stream: $('#stream'), welcome: $('#welcome'),
  input: $('#input'), send: $('#sendBtn'), stop: $('#stopBtn'), composer: $('#composer'),
  chatList: $('#chatList'), title: $('#chatTitle'), attachments: $('#attachments'),
  filesBody: $('#filesBody'), fileCount: $('#fileCount'), drawer: $('#filesDrawer'),
  modal: $('#settingsModal'), toasts: $('#toasts'), modeSwitch: $('#modeSwitch'),
  modeHint: $('#modeHint'), tokenInfo: $('#tokenInfo'), scrollDown: $('#scrollDown'),
  sidebar: $('#sidebar'), scrim: $('#scrim'),
};

let chat = null;
let attachments = [];
let controller = null;
let autoScroll = true;

const AVATAR = '<svg viewBox="0 0 24 24"><path d="M16 8a6 6 0 100 8"/></svg>';
const MAX_AGENT_STEPS = 14;

/* ============================ boot ============================ */

document.documentElement.dataset.theme = state.settings.theme;

fetch('/api/config')
  .then((r) => r.json())
  .then((c) => { if (c.model) $('#modelBadge').textContent = prettyModel(c.model); })
  .catch(() => {});

function prettyModel(id) {
  const tail = id.split('/').pop().replace(/-/g, ' ');
  return tail.replace(/\b\w/g, (c) => c.toUpperCase()).replace(/\bK(\d)\b/, 'K$1');
}

const firstId = state.order.find((id) => state.chats[id]);
openChat(firstId ? state.chats[firstId] : createChat());
renderSidebar();
renderFiles();
syncSettingsForm();

/* ============================ rendering ============================ */

function openChat(next) {
  chat = next;
  ui.title.textContent = chat.title;
  setMode(chat.mode || 'chat', false);
  ui.messages.innerHTML = '';
  chat.messages.filter(isVisible).forEach((m) => ui.messages.append(renderMessage(m)));
  ui.welcome.classList.toggle('hidden', chat.messages.length > 0);
  renderSidebar();
  requestAnimationFrame(() => scrollToBottom(true));
}

// Tool plumbing lives in the transcript but is shown through step cards instead.
// Declared as a function so the boot sequence above can reach it.
function isVisible(m) {
  return m.role === 'user' || (m.role === 'assistant' && (m.content || m.steps?.length || m.reasoning));
}

function renderMessage(m) {
  const node = el('div', `msg ${m.role}`);
  node.dataset.id = m.id;

  const avatar = el('div', 'avatar', m.role === 'user' ? 'You' : AVATAR);
  if (m.role === 'user') avatar.textContent = 'You';
  node.append(avatar);

  const bubble = el('div', 'bubble');
  bubble.append(el('div', 'who', m.role === 'user' ? 'You' : 'Clovyre'));

  if (m.role === 'user') {
    const body = el('div', 'body');
    body.textContent = m.display ?? m.content;
    bubble.append(body);
    if (m.files?.length) {
      const chips = el('div', 'attachments');
      m.files.forEach((f) => chips.append(el('div', 'chip', `<span>${escapeHtml(f.name)}</span>`)));
      bubble.append(chips);
    }
  } else {
    bubble.append(reasoningCard(m.reasoning || ''));
    const steps = el('div', 'steps');
    (m.steps || []).forEach((s) => steps.append(stepCard(s)));
    bubble.append(steps);
    const prose = el('div', 'prose');
    prose.innerHTML = renderMarkdown(m.content || '');
    bubble.append(prose);
  }

  bubble.append(actionBar(m));
  node.append(bubble);
  return node;
}

// Kimi K3 streams its chain of thought on a separate channel; keep it tucked away.
function reasoningCard(text, live = false) {
  const card = el('details', 'step reasoning');
  card.hidden = !text;
  card.innerHTML = `
    <summary>
      <i class="dot${live ? ' run' : ''}"></i>
      <b>${live ? 'Thinking…' : 'Thought process'}</b>
    </summary>
    <div class="step-body"><pre></pre></div>`;
  card.querySelector('pre').textContent = text;
  return card;
}

function updateReasoning(card, text, live) {
  card.hidden = !text;
  card.querySelector('pre').textContent = text;
  card.querySelector('b').textContent = live ? 'Thinking…' : 'Thought process';
  card.querySelector('.dot').classList.toggle('run', live);
}

function stepCard(step) {
  const card = el('details', 'step');
  card.open = false;
  const label = step.name === 'plan' ? 'Planning' : step.name;
  const detail = summarizeArgs(step.name, step.args || {});
  card.innerHTML = `
    <summary>
      <i class="dot${step.running ? ' run' : ''}"></i>
      <b>${escapeHtml(label)}</b>
      <span>${escapeHtml(detail)}</span>
    </summary>
    <div class="step-body"></div>`;
  const body = card.querySelector('.step-body');

  if (step.name === 'plan' && step.args?.steps) {
    const list = el('ol');
    step.args.steps.forEach((s) => { const li = el('li'); li.textContent = s; list.append(li); });
    body.append(list);
  } else {
    if (step.args && Object.keys(step.args).length) {
      const pre = el('pre');
      pre.textContent = JSON.stringify(step.args, null, 2).slice(0, 4000);
      body.append(pre);
    }
    if (step.result) {
      const pre = el('pre');
      pre.textContent = String(step.result).slice(0, 2000);
      body.append(pre);
    }
  }

  if (step.file) body.append(fileCard(step.file));
  return card;
}

function fileCard(path) {
  const file = state.files[path];
  const card = el('div', 'file-card');
  card.innerHTML = `
    <div class="ico"><svg viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8z"/><path d="M14 3v5h5"/></svg></div>
    <div class="meta">
      <b>${escapeHtml(path)}</b>
      <small>${file ? `${file.language} · ${bytes(file.content.length)}` : 'removed'}</small>
    </div>`;
  card.title = 'Open in workspace';
  card.onclick = () => { openDrawer(); highlightFile(path); };
  return card;
}

function actionBar(m) {
  const bar = el('div', 'actions');
  const btn = (title, path, fn) => {
    const b = el('button', null, `<svg viewBox="0 0 24 24">${path}</svg>`);
    b.title = title;
    b.onclick = fn;
    bar.append(b);
    return b;
  };

  btn('Copy', '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 012-2h10"/>', async () => {
    await navigator.clipboard.writeText(m.content || '');
    toast('Copied');
  });

  if (m.role === 'assistant') {
    btn('Regenerate', '<path d="M21 12a9 9 0 11-3-6.7L21 8"/><path d="M21 3v5h-5"/>', () => regenerate(m));
  } else {
    btn('Edit', '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4z"/>', () => editUserMessage(m));
  }
  return bar;
}

function renderSidebar() {
  const query = $('#searchChats').value;
  ui.chatList.innerHTML = '';
  const groups = groupChats(query);
  if (!groups.length) {
    ui.chatList.append(el('div', 'group-label', query ? 'No matches' : 'No conversations yet'));
    return;
  }
  for (const g of groups) {
    ui.chatList.append(el('div', 'group-label', g.label));
    for (const c of g.chats) {
      const item = el('button', `chat-item${c.id === chat?.id ? ' active' : ''}`);
      item.innerHTML = `<span></span>
        <span class="del" title="Delete"><svg viewBox="0 0 24 24"><path d="M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2M6 7l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13"/></svg></span>`;
      item.firstElementChild.textContent = c.title;
      item.onclick = (e) => {
        if (e.target.closest('.del')) {
          deleteChat(c.id);
          if (chat?.id === c.id) {
            const nextId = state.order.find((id) => state.chats[id]);
            openChat(nextId ? state.chats[nextId] : createChat());
          } else renderSidebar();
          return;
        }
        if (c.id !== chat?.id) { openChat(c); closeSidebar(); }
      };
      ui.chatList.append(item);
    }
  }
}

function renderFiles() {
  const files = Object.values(state.files).sort((a, b) => b.updatedAt - a.updatedAt);
  ui.fileCount.textContent = files.length;
  ui.filesBody.innerHTML = '';
  if (!files.length) {
    ui.filesBody.append(el('div', 'empty', 'Files Clovyre creates — or that you save from a code block — collect here.'));
    return;
  }
  for (const f of files) {
    const card = el('details', 'step');
    card.dataset.path = f.name;
    card.innerHTML = `
      <summary>
        <i class="dot"></i><b>${escapeHtml(f.name)}</b>
        <span>${bytes(f.content.length)}</span>
      </summary>
      <div class="step-body"></div>`;
    const body = card.querySelector('.step-body');
    const pre = el('pre');
    pre.textContent = f.content.slice(0, 6000);
    body.append(pre);

    const row = el('div', 'actions');
    row.style.opacity = 1;
    const mk = (title, path, fn) => {
      const b = el('button', null, `<svg viewBox="0 0 24 24">${path}</svg>`);
      b.title = title; b.onclick = fn; row.append(b);
    };
    mk('Download', '<path d="M12 3v12M8 11l4 4 4-4M5 21h14"/>', () => download(f.name, f.content));
    mk('Copy', '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 012-2h10"/>', async () => {
      await navigator.clipboard.writeText(f.content); toast('Copied');
    });
    mk('Attach to next message', '<path d="M21 11l-8.5 8.5a5 5 0 01-7-7L14 4a3.5 3.5 0 015 5l-8.5 8.5a2 2 0 11-2.8-2.8L16 6.5"/>', () => {
      attachments.push({ name: f.name, text: f.content });
      renderAttachments(); toast(`Attached ${f.name}`);
    });
    mk('Delete', '<path d="M4 7h16M6 7l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13"/>', () => {
      deleteFile(f.name); renderFiles();
    });
    body.append(row);
    ui.filesBody.append(card);
  }
}

function highlightFile(path) {
  const card = ui.filesBody.querySelector(`[data-path="${CSS.escape(path)}"]`);
  if (!card) return;
  card.open = true;
  card.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}

/* ============================ sending ============================ */

async function send() {
  const text = ui.input.value.trim();
  if ((!text && !attachments.length) || controller) return;

  const files = attachments.slice();
  attachments = [];
  ui.input.value = '';
  autosize();
  renderAttachments();

  const parts = [text];
  for (const f of files) {
    parts.push(`\n\n<file name="${f.name}">\n${f.text}\n</file>`);
  }

  const userMsg = {
    id: uid(), role: 'user',
    content: parts.join('').trim(),
    display: text || files.map((f) => f.name).join(', '),
    files: files.map((f) => ({ name: f.name })),
  };
  chat.messages.push(userMsg);
  ui.welcome.classList.add('hidden');
  ui.messages.append(renderMessage(userMsg));
  touch(chat);
  scrollToBottom(true);

  await run();
  maybeTitle();
}

async function regenerate(m) {
  if (controller) return;
  const idx = chat.messages.findIndex((x) => x.id === m.id);
  if (idx < 0) return;
  // Drop this assistant turn and any tool plumbing that belonged to it.
  chat.messages.splice(idx);
  openChat(chat);
  await run();
}

function editUserMessage(m) {
  if (controller) return;
  const idx = chat.messages.findIndex((x) => x.id === m.id);
  ui.input.value = m.display ?? m.content;
  autosize();
  ui.input.focus();
  chat.messages.splice(idx);
  openChat(chat);
}

function buildRequestMessages() {
  const agent = chat.mode === 'agent';
  const system = [state.settings.system || DEFAULT_SYSTEM_PROMPT, agent ? AGENT_SYSTEM : '']
    .filter(Boolean)
    .join('\n\n');

  const msgs = [{ role: 'system', content: system }];
  for (const m of chat.messages) {
    if (m.role === 'user') msgs.push({ role: 'user', content: m.content });
    else if (m.role === 'tool') msgs.push({ role: 'tool', tool_call_id: m.tool_call_id, content: m.content });
    else if (m.role === 'assistant') {
      const entry = { role: 'assistant', content: m.content || '' };
      if (m.tool_calls?.length) entry.tool_calls = m.tool_calls;
      msgs.push(entry);
    }
  }
  return msgs;
}

async function run() {
  controller = new AbortController();
  ui.send.classList.add('hidden');
  ui.stop.classList.remove('hidden');

  let steps = 0;
  let turn = null;

  try {
    // Agent mode loops: model -> tools -> model, until it answers without tools.
    // Each model turn is its own message, so a reloaded transcript looks identical.
    while (true) {
      turn = beginTurn();
      const toolCalls = await streamTurn(turn.msg, turn.prose, turn.reasoning);
      finishTurn(turn);
      if (!toolCalls.length) break;

      if (++steps > MAX_AGENT_STEPS) {
        turn.msg.content += `\n\n_Stopped after ${MAX_AGENT_STEPS} tool steps._`;
        turn.prose.innerHTML = renderMarkdown(turn.msg.content);
        break;
      }

      for (const call of toolCalls) {
        let args = {};
        try {
          args = JSON.parse(call.function.arguments || '{}');
        } catch {
          args = { _raw: call.function.arguments };
        }

        const step = { name: call.function.name, args, running: true };
        turn.msg.steps.push(step);
        let card = stepCard(step);
        turn.stepsBox.append(card);
        scrollToBottom();

        const { result, effect } = await runTool(call.function.name, args);
        step.running = false;
        step.result = result;
        if (effect?.kind === 'file') step.file = effect.path;

        const fresh = stepCard(step);
        card.replaceWith(fresh);
        card = fresh;
        renderFiles();

        chat.messages.push({
          id: uid(), role: 'tool', tool_call_id: call.id,
          name: call.function.name, content: result,
        });
        scrollToBottom();
      }
      save();
    }
  } catch (err) {
    if (err.name !== 'AbortError') {
      // Keep the failed turn on screen so the error survives the toast.
      if (turn) turn.msg.content = `${turn.msg.content || ''}\n\n> **Something went wrong.** ${err.message}`.trim();
      toast(err.message, true);
    }
  } finally {
    if (turn) finishTurn(turn);
    controller = null;
    ui.send.classList.remove('hidden');
    ui.stop.classList.add('hidden');
    touch(chat);
    scrollToBottom();
  }
}

/** Create the transcript entry + DOM node for one model turn. */
function beginTurn() {
  const msg = { id: uid(), role: 'assistant', content: '', steps: [] };
  chat.messages.push(msg);
  const node = renderMessage(msg);
  node.classList.add('streaming');
  ui.messages.append(node);
  const prose = node.querySelector('.prose');
  prose.innerHTML = '<div class="thinking"><i></i><i></i><i></i></div>';
  scrollToBottom();
  return {
    msg, node, prose,
    stepsBox: node.querySelector('.steps'),
    reasoning: node.querySelector('.reasoning'),
  };
}

function finishTurn(turn) {
  turn.node.classList.remove('streaming');
  turn.prose.innerHTML = renderMarkdown(turn.msg.content || '');
  wireCodeBlocks(turn.prose);
  updateReasoning(turn.reasoning, turn.msg.reasoning || '', false);
  // A turn that only called tools has nothing to show but its step cards.
  if (!turn.msg.content && !turn.msg.steps.length && !turn.msg.reasoning) turn.node.remove();
  save();
}

/**
 * Stream one completion into `msg`, painting into `prose` as tokens arrive.
 * @returns {Promise<Array>} the tool calls the model asked for (possibly empty)
 */
async function streamTurn(msg, prose, reasoningCardEl) {
  const body = {
    messages: buildRequestMessages(),
    temperature: state.settings.temperature,
    top_p: state.settings.topP,
    max_tokens: state.settings.maxTokens,
  };
  if (chat.mode === 'agent') body.tools = TOOLS;

  const res = await fetch('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: controller.signal,
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.error ? `${err.error}${err.detail ? ` — ${err.detail}` : ''}` : `Request failed (${res.status})`);
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  const toolCalls = [];
  let buffer = '';
  let painted = false;
  let frame = 0;

  const paint = () => {
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(() => {
      prose.innerHTML = renderMarkdown(msg.content) + '<span class="cursor"></span>';
      scrollToBottom();
    });
  };

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    const lines = buffer.split('\n');
    buffer = lines.pop();

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      const data = trimmed.slice(5).trim();
      if (!data || data === '[DONE]') continue;

      let chunk;
      try { chunk = JSON.parse(data); } catch { continue; }

      if (chunk.error) throw new Error(chunk.error.message || 'Upstream error');
      if (chunk.usage) {
        const total = chunk.usage.total_tokens ?? (chunk.usage.prompt_tokens || 0) + (chunk.usage.completion_tokens || 0);
        if (total) ui.tokenInfo.textContent = `${total} tok`;
      }

      const delta = chunk.choices?.[0]?.delta;
      if (!delta) continue;

      const thought = delta.reasoning_content ?? delta.reasoning;
      if (thought) {
        msg.reasoning = (msg.reasoning || '') + thought;
        updateReasoning(reasoningCardEl, msg.reasoning, true);
        if (!painted) prose.innerHTML = '<div class="thinking"><i></i><i></i><i></i></div>';
        scrollToBottom();
      }

      if (delta.content) {
        if (!painted) { prose.innerHTML = ''; painted = true; }
        msg.content += delta.content;
        paint();
      }

      for (const tc of delta.tool_calls || []) {
        const slot = tc.index ?? 0;
        toolCalls[slot] = toolCalls[slot] || { id: '', type: 'function', function: { name: '', arguments: '' } };
        if (tc.id) toolCalls[slot].id = tc.id;
        if (tc.function?.name) toolCalls[slot].function.name += tc.function.name;
        if (tc.function?.arguments) toolCalls[slot].function.arguments += tc.function.arguments;
      }
    }
  }

  cancelAnimationFrame(frame);
  const calls = toolCalls.filter(Boolean).map((c, i) => ({ ...c, id: c.id || `call_${Date.now()}_${i}` }));
  if (calls.length) msg.tool_calls = calls;
  return calls;
}

async function maybeTitle() {
  if (!state.settings.autoTitle) return;
  if (chat.title !== 'New conversation') return;
  const first = chat.messages.find((m) => m.role === 'user');
  if (!first) return;

  // Show something immediately; the model's suggestion replaces it if it lands.
  const source = (first.display ?? first.content).replace(/\s+/g, ' ').trim();
  setTitle(source.length > 42 ? `${source.slice(0, 42)}…` : source);

  try {
    const res = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      // Generous budget: the model spends tokens on reasoning before answering.
      body: JSON.stringify({
        max_tokens: 512,
        temperature: 0.2,
        messages: [
          { role: 'system', content: 'Reply with nothing but a title of at most 5 words for the conversation this message starts. No quotes, no trailing punctuation, no explanation.' },
          { role: 'user', content: source.slice(0, 800) },
        ],
      }),
    });
    if (!res.ok) return;
    const text = await res.text();
    let title = '';
    for (const line of text.split('\n')) {
      if (!line.startsWith('data:')) continue;
      const payload = line.slice(5).trim();
      if (payload === '[DONE]') continue;
      try { title += JSON.parse(payload).choices?.[0]?.delta?.content || ''; } catch { /* skip */ }
    }
    title = title.split('\n').map((l) => l.trim()).filter(Boolean).pop() || '';
    title = title.replace(/^["'\s]+|["'.\s]+$/g, '').slice(0, 60);
    if (title) setTitle(title);
  } catch { /* a missing title is not worth surfacing */ }
}

function setTitle(title) {
  chat.title = title;
  ui.title.textContent = title;
  touch(chat);
  renderSidebar();
}

/* ============================ code blocks & files ============================ */

function wireCodeBlocks(root) {
  root.querySelectorAll('.code-block').forEach((block) => {
    const raw = block.dataset.raw ?? '';
    block.querySelector('[data-act="copy"]')?.addEventListener('click', async () => {
      await navigator.clipboard.writeText(raw);
      toast('Copied');
    });
    block.querySelector('[data-act="save"]')?.addEventListener('click', () => {
      const lang = block.dataset.lang || '';
      const guessed = filenameFrom(raw, lang);
      const name = prompt('Save to workspace as:', guessed);
      if (!name) return;
      writeFile(name, raw, guessLanguage(name));
      renderFiles();
      toast(`Saved ${name}`);
    });
  });
}

function filenameFrom(code, lang) {
  const hint = code.match(/^\s*(?:\/\/|#|<!--)\s*([\w./-]+\.\w{1,5})/);
  if (hint) return hint[1].replace(/^\.\//, '');
  const ext = {
    javascript: 'js', typescript: 'ts', python: 'py', html: 'html', css: 'css', json: 'json',
    bash: 'sh', sh: 'sh', markdown: 'md', md: 'md', yaml: 'yml', sql: 'sql', java: 'java',
    go: 'go', rust: 'rs', c: 'c', cpp: 'cpp', ruby: 'rb', php: 'php', jsx: 'jsx', tsx: 'tsx',
  }[lang.toLowerCase()] || 'txt';
  return `snippet-${Object.keys(state.files).length + 1}.${ext}`;
}

function download(name, content) {
  const url = URL.createObjectURL(new Blob([content], { type: 'text/plain;charset=utf-8' }));
  const a = el('a');
  a.href = url;
  a.download = name.split('/').pop();
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function addFiles(list) {
  for (const file of list) {
    if (file.size > 2 * 1024 * 1024) { toast(`${file.name} is too large (2 MB max)`, true); continue; }
    try {
      const text = await file.text();
      attachments.push({ name: file.name, text });
    } catch {
      toast(`Could not read ${file.name}`, true);
    }
  }
  renderAttachments();
}

function renderAttachments() {
  ui.attachments.innerHTML = '';
  attachments.forEach((f, i) => {
    const chip = el('div', 'chip', `<span>${escapeHtml(f.name)}</span>
      <button title="Remove"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button>`);
    chip.querySelector('button').onclick = () => { attachments.splice(i, 1); renderAttachments(); };
    ui.attachments.append(chip);
  });
}

/* ============================ chrome ============================ */

function toast(message, isError = false) {
  const t = el('div', `toast${isError ? ' err' : ''}`);
  t.textContent = message;
  ui.toasts.append(t);
  setTimeout(() => t.remove(), isError ? 6000 : 2200);
}

function scrollToBottom(force = false) {
  if (!autoScroll && !force) return;
  ui.stream.scrollTop = ui.stream.scrollHeight;
}

function autosize() {
  ui.input.style.height = 'auto';
  ui.input.style.height = `${ui.input.scrollHeight}px`;
  ui.send.disabled = !ui.input.value.trim() && !attachments.length;
}

function setMode(mode, persist = true) {
  chat.mode = mode;
  [...ui.modeSwitch.children].forEach((b) => b.classList.toggle('active', b.dataset.mode === mode));
  ui.modeHint.textContent = mode === 'agent' ? 'Agent mode · builds files for you' : 'Chat mode';
  ui.input.placeholder = mode === 'agent' ? 'Describe what you want built…' : 'Message Clovyre…';
  if (persist) save();
}

const openDrawer = () => ui.drawer.setAttribute('aria-hidden', 'false');
const closeSidebar = () => { ui.sidebar.classList.remove('open'); ui.scrim.classList.remove('show'); };

/* ============================ events ============================ */

ui.send.onclick = send;
ui.stop.onclick = () => controller?.abort();

ui.input.addEventListener('input', autosize);
ui.input.addEventListener('keydown', (e) => {
  const enterSends = state.settings.sendOnEnter;
  if (e.key === 'Enter' && !e.shiftKey && enterSends) { e.preventDefault(); send(); }
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
});

$('#newChat').onclick = () => { openChat(createChat()); closeSidebar(); ui.input.focus(); };
$('#searchChats').oninput = renderSidebar;
$('#menuBtn').onclick = () => { ui.sidebar.classList.add('open'); ui.scrim.classList.add('show'); };
ui.scrim.onclick = closeSidebar;

ui.modeSwitch.onclick = (e) => {
  const btn = e.target.closest('button');
  if (btn) { setMode(btn.dataset.mode); touch(chat); }
};

$('#themeBtn').onclick = () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  state.settings.theme = next;
  save();
};

$('#exportChat').onclick = () => {
  const lines = [`# ${chat.title}`, ''];
  for (const m of chat.messages) {
    if (m.role === 'user') lines.push(`**You**\n\n${m.display ?? m.content}\n`);
    else if (m.role === 'assistant' && m.content) lines.push(`**Clovyre**\n\n${m.content}\n`);
  }
  download(`${chat.title.replace(/[^\w -]/g, '').trim() || 'conversation'}.md`, lines.join('\n'));
};

$('#attachBtn').onclick = () => $('#fileInput').click();
$('#fileInput').onchange = (e) => { addFiles(e.target.files); e.target.value = ''; };

ui.composer.addEventListener('dragover', (e) => { e.preventDefault(); ui.composer.classList.add('drag'); });
ui.composer.addEventListener('dragleave', () => ui.composer.classList.remove('drag'));
ui.composer.addEventListener('drop', (e) => {
  e.preventDefault();
  ui.composer.classList.remove('drag');
  addFiles(e.dataTransfer.files);
});

ui.stream.addEventListener('scroll', () => {
  const gap = ui.stream.scrollHeight - ui.stream.scrollTop - ui.stream.clientHeight;
  autoScroll = gap < 120;
  ui.scrollDown.classList.toggle('hidden', autoScroll);
});
ui.scrollDown.onclick = () => { autoScroll = true; scrollToBottom(true); };

$('#openFiles').onclick = openDrawer;
$('#closeFiles').onclick = () => ui.drawer.setAttribute('aria-hidden', 'true');
$('#downloadAll').onclick = () => {
  const files = Object.values(state.files);
  if (!files.length) return toast('Workspace is empty');
  files.forEach((f, i) => setTimeout(() => download(f.name, f.content), i * 250));
};

document.querySelectorAll('.suggestions button').forEach((b) => {
  b.onclick = () => { ui.input.value = b.dataset.prompt; autosize(); send(); };
});

/* settings */
const openSettings = () => ui.modal.setAttribute('aria-hidden', 'false');
$('#openSettings').onclick = openSettings;
$('#closeSettings').onclick = () => ui.modal.setAttribute('aria-hidden', 'true');
ui.modal.onclick = (e) => { if (e.target === ui.modal) ui.modal.setAttribute('aria-hidden', 'true'); };

function syncSettingsForm() {
  const s = state.settings;
  $('#systemPrompt').value = s.system;
  $('#temperature').value = s.temperature;
  $('#tempVal').textContent = Number(s.temperature).toFixed(2);
  $('#topP').value = s.topP;
  $('#topPVal').textContent = Number(s.topP).toFixed(2);
  $('#maxTokens').value = s.maxTokens;
  $('#autoTitle').checked = s.autoTitle;
  $('#sendOnEnter').checked = s.sendOnEnter;
}

$('#systemPrompt').oninput = (e) => { state.settings.system = e.target.value; save(); };
$('#temperature').oninput = (e) => {
  state.settings.temperature = +e.target.value;
  $('#tempVal').textContent = (+e.target.value).toFixed(2); save();
};
$('#topP').oninput = (e) => {
  state.settings.topP = +e.target.value;
  $('#topPVal').textContent = (+e.target.value).toFixed(2); save();
};
$('#maxTokens').oninput = (e) => { state.settings.maxTokens = +e.target.value || 8192; save(); };
$('#autoTitle').onchange = (e) => { state.settings.autoTitle = e.target.checked; save(); };
$('#sendOnEnter').onchange = (e) => { state.settings.sendOnEnter = e.target.checked; save(); };
$('#clearAll').onclick = () => {
  if (!confirm('Delete every conversation? Workspace files are kept.')) return;
  state.chats = {}; state.order = []; save();
  openChat(createChat());
  toast('All conversations deleted');
};

document.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); $('#searchChats').focus(); }
  if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === 'o') { e.preventDefault(); openChat(createChat()); }
  if (e.key === 'Escape') {
    ui.modal.setAttribute('aria-hidden', 'true');
    ui.drawer.setAttribute('aria-hidden', 'true');
    closeSidebar();
  }
});

autosize();
ui.input.focus();
