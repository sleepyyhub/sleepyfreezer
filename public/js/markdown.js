// Compact markdown renderer + lightweight syntax highlighting.
// Deliberately dependency-free so the app stays self-contained.

export const escapeHtml = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

const KEYWORDS = new RegExp(
  '\\b(' +
    ['const','let','var','function','return','if','else','for','while','class','extends','new','import','from','export',
     'default','async','await','try','catch','finally','throw','typeof','instanceof','in','of','this','super','yield',
     'def','elif','lambda','pass','with','as','not','and','or','None','True','False','self','print','raise','global',
     'public','private','protected','static','void','int','float','double','bool','string','struct','enum','interface',
     'type','fn','let','mut','impl','trait','pub','use','match','where','nil','func','package','end','do','then','begin',
     'select','insert','update','delete','where','null','true','false'].join('|') +
    ')\\b'
);

// Order matters: comments and strings are masked before keywords run.
export function highlight(code, lang = '') {
  let html = escapeHtml(code);
  const slots = [];
  // Each masked span becomes one private-use char, so later passes (numbers,
  // keywords) can never match inside an already-highlighted region.
  const stash = (cls, text) =>
    String.fromCharCode(0xe100 + slots.push(`<span class="${cls}">${text}</span>`) - 1);

  if (/^(html|xml|svg|md|markdown)$/i.test(lang)) {
    html = html.replace(/&lt;!--[\s\S]*?--&gt;/g, (m) => stash('tok-com', m));
    html = html.replace(/&lt;\/?[\w:-]+/g, (m) => stash('tok-key', m));
    html = html.replace(/"[^"\n]*"/g, (m) => stash('tok-str', m));
  } else {
    html = html.replace(/(\/\*[\s\S]*?\*\/|\/\/[^\n]*|#[^\n]*|--[^\n]*)/g, (m) => stash('tok-com', m));
    html = html.replace(/('([^'\\\n]|\\.)*'|"([^"\\\n]|\\.)*"|`([^`\\]|\\.)*`)/g, (m) => stash('tok-str', m));
    html = html.replace(/\b\d+(\.\d+)?\b/g, (m) => stash('tok-num', m));
    html = html.replace(/\b([A-Za-z_$][\w$]*)(?=\s*\()/g, (m) => stash('tok-fn', m));
    html = html.replace(KEYWORDS, (m) => stash('tok-key', m));
  }

  return html.replace(/[\uE100-\uEFFF]/g, (ch) => slots[ch.charCodeAt(0) - 0xe100] ?? ch);
}

function inline(src) {
  let s = escapeHtml(src);
  const code = [];
  s = s.replace(/`([^`]+)`/g, (_, c) => `\uE001${code.push(c) - 1}\uE001`);
  s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, '<img src="$2" alt="$1" />');
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  s = s.replace(/(\*\*|__)(?=\S)([\s\S]*?\S)\1/g, '<strong>$2</strong>');
  s = s.replace(/(^|[^*])\*(?=\S)([^*\n]*?\S)\*/g, '$1<em>$2</em>');
  s = s.replace(/(^|[^_])_(?=\S)([^_\n]*?\S)_/g, '$1<em>$2</em>');
  s = s.replace(/~~(?=\S)([\s\S]*?\S)~~/g, '<del>$1</del>');
  // The stashed text came from the already-escaped string \u2014 escaping it again
  // would render entities literally (`&quot;` instead of `"`).
  s = s.replace(/\uE001(\d+)\uE001/g, (_, i) => `<code>${code[+i]}</code>`);
  return s;
}

const codeBlockHtml = (lang, body, open) => `
<div class="code-block" data-lang="${escapeHtml(lang)}" data-raw="${escapeHtml(body)}">
  <header>
    <span>${escapeHtml(lang || 'text')}</span>
    <div class="spacer"></div>
    ${open ? '' : `
    <button data-act="save" title="Save to workspace"><svg viewBox="0 0 24 24"><path d="M19 21H5a2 2 0 01-2-2V5a2 2 0 012-2h11l5 5v11a2 2 0 01-2 2z"/><path d="M17 21v-8H7v8M7 3v5h8"/></svg></button>
    <button data-act="copy" title="Copy"><svg viewBox="0 0 24 24"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 012-2h10"/></svg></button>`}
  </header>
  <pre><code>${highlight(body, lang)}</code></pre>
</div>`;

/**
 * Render markdown to HTML. An unterminated final fence is rendered as an
 * in-progress block so streaming code looks right while it arrives.
 */
export function renderMarkdown(src = '') {
  const out = [];
  const lines = src.split('\n');
  let i = 0;

  const flushParagraph = (buf) => {
    if (buf.length) out.push(`<p>${inline(buf.join('\n')).replace(/\n/g, '<br />')}</p>`);
    buf.length = 0;
  };
  const para = [];

  while (i < lines.length) {
    const line = lines[i];

    // fenced code
    const fence = line.match(/^\s*(`{3,}|~{3,})\s*([\w+#.-]*)/);
    if (fence) {
      flushParagraph(para);
      const marker = fence[1][0];
      const closeRe = new RegExp(`^\\s*\\${marker}{3,}\\s*$`);
      const lang = fence[2] || '';
      const body = [];
      i++;
      let closed = false;
      while (i < lines.length) {
        if (closeRe.test(lines[i])) { closed = true; i++; break; }
        body.push(lines[i++]);
      }
      out.push(codeBlockHtml(lang, body.join('\n'), !closed));
      continue;
    }

    if (/^\s*(---|\*\*\*|___)\s*$/.test(line)) { flushParagraph(para); out.push('<hr />'); i++; continue; }

    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) { flushParagraph(para); out.push(`<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`); i++; continue; }

    if (/^\s*>\s?/.test(line)) {
      flushParagraph(para);
      const buf = [];
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) buf.push(lines[i++].replace(/^\s*>\s?/, ''));
      out.push(`<blockquote>${renderMarkdown(buf.join('\n'))}</blockquote>`);
      continue;
    }

    // table
    if (/\|/.test(line) && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1])) {
      flushParagraph(para);
      const cells = (l) => l.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map((c) => c.trim());
      const head = cells(lines[i]); i += 2;
      const rows = [];
      while (i < lines.length && /\|/.test(lines[i]) && lines[i].trim()) rows.push(cells(lines[i++]));
      out.push(
        `<table><thead><tr>${head.map((c) => `<th>${inline(c)}</th>`).join('')}</tr></thead><tbody>` +
          rows.map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join('')}</tr>`).join('') +
          '</tbody></table>'
      );
      continue;
    }

    // lists (one level of nesting via recursion on indented blocks)
    const li = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
    if (li) {
      flushParagraph(para);
      const ordered = /\d/.test(li[2]);
      const items = [];
      while (i < lines.length) {
        const m = lines[i].match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
        if (!m || m[1].length > 3) break;
        if (ordered !== /\d/.test(m[2])) break;
        const buf = [m[3]];
        i++;
        while (i < lines.length && /^\s{2,}\S/.test(lines[i])) buf.push(lines[i++].replace(/^\s{2}/, ''));
        items.push(buf.join('\n'));
      }
      const body = items
        .map((t) => `<li>${t.includes('\n') ? renderMarkdown(t) : inline(t)}</li>`)
        .join('');
      out.push(ordered ? `<ol>${body}</ol>` : `<ul>${body}</ul>`);
      continue;
    }

    if (!line.trim()) { flushParagraph(para); i++; continue; }

    para.push(line);
    i++;
  }
  flushParagraph(para);
  return out.join('\n');
}
