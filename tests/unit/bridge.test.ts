import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parse } from 'luaparse';
import { describe, expect, it } from 'vitest';
import { TOOL_DEFINITIONS } from '../../src/lib/tools/registry';
import { SAFE_PROPERTIES } from '../../src/lib/tools/safe-properties';

/**
 * Static checks on the Roblox bridge.
 *
 * client.lua cannot be exercised in CI — there is no Roblox client to run it —
 * so it is the one file with no behavioural coverage. These tests guard the
 * failures that would otherwise only surface in production: a syntax error that
 * breaks every session, a tool the server offers that the bridge cannot answer,
 * and drift between the two copies of the safe-property registry.
 */

const source = readFileSync(join(process.cwd(), 'roblox', 'client.lua'), 'utf8');

describe('roblox/client.lua', () => {
  it('attributes remote calls without trusting the bridge\u2019s own stack frames', () => {
    // The hook runs inside client.lua, so the nearest frames are always this
    // bridge. Reporting one of those as the caller would name Clovyre as the
    // origin of every call it observes.
    expect(source).toContain('OWN_SOURCE');
    expect(source).toContain('source ~= OWN_SOURCE');
    // Attribution runs inside a hot hook and must never throw into the game.
    expect(source).toMatch(/pcall\(function\(\)\s*\n\s*return debug\.info/);
  });

  it('bounds the call-site window it retains', () => {
    // Call sites hold script references; keeping every one would pin instances
    // in memory for the life of the session.
    expect(source).toContain('CALL_SITE_LIMIT');
    expect(source).toContain('table.remove(callSiteOrder, 1)');
  });

  it('never writes to the executor console outside the gated log helpers', () => {
    // Console output is opt-in per session, so a bare print()/warn() anywhere in
    // the bridge would leak into the user's own output window regardless of the
    // setting. Only info() and warnLog() may reach the console, and both check
    // the flag the server pushes.
    const offenders: string[] = [];
    source.split('\n').forEach((line, index) => {
      const code = line.replace(/--.*$/, '');
      if (!/(^|[^%\w.])(print|warn)\s*\(/.test(code)) return;
      offenders.push(`${index + 1}: ${line.trim()}`);
    });

    // The two permitted call sites live inside info() and warnLog().
    expect(offenders).toHaveLength(2);
    for (const offender of offenders) {
      expect(offender).toMatch(/\[Clovyre\]/);
    }
    expect(source).toContain('if consoleOutput then');
  });

  it('keeps a stable client key so re-running replaces instead of stacking', () => {
    // The key must persist in getgenv: a fresh key on every run would make one
    // person's repeated executions look like a crowd of different clients.
    expect(source).toContain('genv.__ClovyreClientKey');
    expect(source).toContain('clientKey = getClientKey()');
  });

  it('is syntactically valid Lua', () => {
    expect(() => parse(source, { luaVersion: '5.3', comments: false })).not.toThrow();
  });

  it('implements a handler for every remote tool the server offers', () => {
    const implemented = new Set(
      [...source.matchAll(/^handlers\.(\w+)\s*=\s*function/gm)].map((match) => match[1]!),
    );

    const missing = TOOL_DEFINITIONS.filter((tool) => !tool.local).filter(
      // The bridge strips the clovyre_ prefix when dispatching.
      (tool) => !implemented.has(tool.name.replace(/^clovyre_/, '')),
    );

    expect(missing.map((tool) => tool.name)).toEqual([]);
  });

  it('exposes the documented global entry points', () => {
    expect(source).toContain('getgenv().ClovyreDisconnect');
    expect(source).toContain('ClovyreConfig');
    expect(source).toMatch(/genv\.ClovyreDisconnect = function/);
  });

  it('declares the transport before the handlers that push through it', () => {
    // A handler closing over a not-yet-declared local would silently read a nil
    // global instead, and every pushed event would vanish.
    const declaration = source.indexOf('\nlocal sendRaw\n');
    const firstPush = source.indexOf('local function pushEvent');
    const assignment = source.indexOf('\nsendRaw = function(');

    expect(declaration).toBeGreaterThan(-1);
    expect(firstPush).toBeGreaterThan(declaration);
    expect(assignment).toBeGreaterThan(declaration);
  });

  it('never offers a way to fire a remote', () => {
    // The remote spy observes traffic. Sending traffic is a different capability
    // and is deliberately absent; this test exists to keep it that way.
    expect(source).not.toMatch(/handlers\.(fire_remote|remote_fire|invoke_remote)/);
    expect(source).not.toMatch(/:FireServer\(/);
    expect(source).not.toMatch(/:InvokeServer\(/);
  });

  it('keeps the safe-property registry in step with the server', () => {
    // Both copies are hand-maintained; drift means a property the server thinks
    // is readable that the bridge rejects, or vice versa.
    for (const className of ['BasePart', 'Humanoid', 'Player', 'Camera', 'GuiObject']) {
      const block = new RegExp(`${className} = \\{([^}]*)\\}`, 's').exec(source);
      expect(block, `${className} missing from client.lua`).not.toBeNull();

      const luaProperties = new Set(
        [...block![1]!.matchAll(/'([A-Za-z0-9_]+)'/g)].map((match) => match[1]!),
      );
      for (const property of SAFE_PROPERTIES[className] ?? []) {
        expect(
          luaProperties.has(property),
          `${className}.${property} missing from client.lua`,
        ).toBe(true);
      }
    }
  });

  it('probes every capability the protocol declares it may report', () => {
    for (const capability of [
      'decompile',
      'getloadedmodules',
      'getconnections',
      'getgc',
      'getsenv',
      'identifyexecutor',
      'hookmetamethod',
      'getnamecallmethod',
    ]) {
      expect(source, `${capability} is never probed`).toContain(capability);
    }
  });

  it('bounds every payload it sends', () => {
    expect(source).toContain('maxPayloadBytes');
    expect(source).toContain('PAYLOAD_TOO_LARGE');
    expect(source).toMatch(/LIMITS\s*=\s*\{/);
  });
});
