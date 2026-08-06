// Agent mode: tool definitions + client-side execution against the workspace.
// Tools run entirely in the browser — no code is executed on the server.

import { state, writeFile, deleteFile, guessLanguage } from './store.js';

export const AGENT_SYSTEM =
  'You are Clovyre in Agent mode: an autonomous builder. You have tools that read and write files in the ' +
  "user's workspace, plus a scratchpad for planning.\n\n" +
  'How to work:\n' +
  '1. Start by calling `plan` with a short numbered breakdown of what you will do.\n' +
  '2. Then actually do it — call `write_file` for every artifact you produce. Never paste a full file into ' +
  'the chat when you could write it; the workspace is the deliverable.\n' +
  '3. Use `read_file` / `list_files` before editing something that already exists, and `edit_file` for ' +
  'targeted changes rather than rewriting whole files.\n' +
  '4. Prefer complete, runnable output over sketches. Multiple files are fine.\n' +
  '5. When everything is done, stop calling tools and write a short summary: what you built, which files, ' +
  'and how to use them.\n\n' +
  'Be decisive. Do not ask permission for routine steps — make a sensible choice, note the assumption, and continue.';

export const TOOLS = [
  {
    type: 'function',
    function: {
      name: 'plan',
      description: 'Record a short step-by-step plan before starting work. Call this first, once.',
      parameters: {
        type: 'object',
        properties: {
          steps: { type: 'array', items: { type: 'string' }, description: 'Ordered steps you intend to take.' },
        },
        required: ['steps'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'write_file',
      description: 'Create a file in the workspace, or replace one that already exists.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'File name or relative path, e.g. "index.html" or "src/app.js".' },
          content: { type: 'string', description: 'Full contents of the file.' },
        },
        required: ['path', 'content'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'read_file',
      description: 'Read the full contents of a workspace file.',
      parameters: {
        type: 'object',
        properties: { path: { type: 'string' } },
        required: ['path'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'list_files',
      description: 'List every file in the workspace with its size.',
      parameters: { type: 'object', properties: {} },
    },
  },
  {
    type: 'function',
    function: {
      name: 'edit_file',
      description: 'Replace an exact substring in an existing file. The old text must appear exactly once.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string' },
          old_text: { type: 'string', description: 'Exact text to replace, including indentation.' },
          new_text: { type: 'string', description: 'Replacement text.' },
        },
        required: ['path', 'old_text', 'new_text'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'delete_file',
      description: 'Remove a file from the workspace.',
      parameters: {
        type: 'object',
        properties: { path: { type: 'string' } },
        required: ['path'],
      },
    },
  },
];

const ok = (data) => JSON.stringify({ ok: true, ...data });
const fail = (message) => JSON.stringify({ ok: false, error: message });

/**
 * Execute one tool call. Always resolves — errors come back as tool results so
 * the model can recover instead of the run dying.
 * @returns {Promise<{result: string, effect?: object}>}
 */
export async function runTool(name, args) {
  try {
    switch (name) {
      case 'plan': {
        const steps = Array.isArray(args.steps) ? args.steps : [];
        return { result: ok({ acknowledged: steps.length }), effect: { kind: 'plan', steps } };
      }

      case 'write_file': {
        if (!args.path) return { result: fail('path is required') };
        const file = writeFile(args.path, args.content ?? '', guessLanguage(args.path));
        return {
          result: ok({ path: file.name, bytes: file.content.length }),
          effect: { kind: 'file', path: file.name },
        };
      }

      case 'read_file': {
        const file = state.files[args.path];
        if (!file) return { result: fail(`No such file: ${args.path}. Use list_files to see what exists.`) };
        return { result: ok({ path: file.name, content: file.content }) };
      }

      case 'list_files': {
        const files = Object.values(state.files).map((f) => ({ path: f.name, bytes: f.content.length }));
        return { result: ok({ files }) };
      }

      case 'edit_file': {
        const file = state.files[args.path];
        if (!file) return { result: fail(`No such file: ${args.path}`) };
        const parts = file.content.split(args.old_text ?? '');
        if (parts.length === 1) return { result: fail('old_text was not found in the file.') };
        if (parts.length > 2) return { result: fail(`old_text appears ${parts.length - 1} times; make it unique.`) };
        const updated = writeFile(file.name, parts.join(args.new_text ?? ''), file.language);
        return {
          result: ok({ path: updated.name, bytes: updated.content.length }),
          effect: { kind: 'file', path: updated.name },
        };
      }

      case 'delete_file': {
        if (!state.files[args.path]) return { result: fail(`No such file: ${args.path}`) };
        deleteFile(args.path);
        return { result: ok({ deleted: args.path }), effect: { kind: 'files-changed' } };
      }

      default:
        return { result: fail(`Unknown tool: ${name}`) };
    }
  } catch (err) {
    return { result: fail(err.message || String(err)) };
  }
}

export const summarizeArgs = (name, args) => {
  if (name === 'plan') return `${(args.steps || []).length} steps`;
  if (name === 'list_files') return '';
  return args.path || '';
};
