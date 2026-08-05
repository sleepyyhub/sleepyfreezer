import { describe, expect, it } from 'vitest';
import { ErrorCodes, PROTOCOL_VERSION, parseClientMessage } from '../../src/lib/protocol/messages';
import {
  formatDisplayPath,
  instanceTargetSchema,
  normalizeTarget,
  parseDisplayPath,
} from '../../src/lib/protocol/path';
import {
  DEFAULT_LIMITS,
  formatValue,
  isTaggedValue,
  normalizeIncoming,
} from '../../src/lib/serialization/roblox-value';
import {
  abbreviate,
  redactHeaders,
  redactText,
  redactValue,
  REDACTED,
} from '../../src/lib/security/redact';
import { RateLimiter } from '../../src/lib/security/rate-limit';
import { isSafeProperty, safePropertiesFor } from '../../src/lib/tools/safe-properties';

const helloFrame = (overrides: Record<string, unknown> = {}) =>
  JSON.stringify({
    protocolVersion: PROTOCOL_VERSION,
    type: 'hello',
    sessionId: 'cs_ABCDEFGHJKMNPQRSTUVW',
    token: 'crx_token',
    capabilities: { websocket: true, decompile: false },
    metadata: { placeId: 1, jobId: 'job' },
    ...overrides,
  });

describe('websocket message parsing', () => {
  it('accepts a well-formed hello', () => {
    const parsed = parseClientMessage(helloFrame());
    expect(parsed.ok).toBe(true);
    if (parsed.ok) expect(parsed.message.type).toBe('hello');
  });

  it('rejects malformed JSON with a structured code', () => {
    const parsed = parseClientMessage('{ not json');
    expect(parsed).toMatchObject({ ok: false, code: ErrorCodes.INVALID_MESSAGE });
  });

  it('rejects a mismatched protocol version distinctly', () => {
    const parsed = parseClientMessage(helloFrame({ protocolVersion: 99 }));
    expect(parsed).toMatchObject({ ok: false, code: ErrorCodes.PROTOCOL_VERSION_MISMATCH });
  });

  it('rejects an unknown message type', () => {
    const parsed = parseClientMessage(
      JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'exfiltrate' }),
    );
    expect(parsed.ok).toBe(false);
  });

  it('rejects a hello missing required fields', () => {
    const parsed = parseClientMessage(
      JSON.stringify({ protocolVersion: PROTOCOL_VERSION, type: 'hello', sessionId: 'cs_x' }),
    );
    expect(parsed.ok).toBe(false);
  });

  it('rejects an oversized string field', () => {
    const parsed = parseClientMessage(helloFrame({ token: 'x'.repeat(5000) }));
    expect(parsed.ok).toBe(false);
  });

  it('accepts a result frame in both success and failure shapes', () => {
    const success = parseClientMessage(
      JSON.stringify({
        protocolVersion: 1,
        type: 'result',
        id: 'cmd_1',
        ok: true,
        result: { a: 1 },
      }),
    );
    const failure = parseClientMessage(
      JSON.stringify({
        protocolVersion: 1,
        type: 'result',
        id: 'cmd_1',
        ok: false,
        error: { code: 'INSTANCE_NOT_FOUND', message: 'gone' },
      }),
    );
    expect(success.ok).toBe(true);
    expect(failure.ok).toBe(true);
  });
});

describe('structured instance paths', () => {
  it('round-trips a name containing a dot', () => {
    const path = { segments: [{ name: 'ReplicatedStorage' }, { name: 'Combat.Controller' }] };
    const display = formatDisplayPath(path);
    expect(display).toBe('ReplicatedStorage.Combat\\.Controller');
    expect(parseDisplayPath(display).segments.map((segment) => segment.name)).toEqual([
      'ReplicatedStorage',
      'Combat.Controller',
    ]);
  });

  it('round-trips a name containing a backslash', () => {
    const path = { segments: [{ name: 'Odd\\Name' }] };
    expect(parseDisplayPath(formatDisplayPath(path)).segments[0]!.name).toBe('Odd\\Name');
  });

  it('prefers a ref over a path when both are present', () => {
    expect(normalizeTarget({ ref: 'ref_7', displayPath: 'Workspace' })).toEqual({ ref: 'ref_7' });
  });

  it('converts a display path into structured segments', () => {
    expect(normalizeTarget({ displayPath: 'Workspace.Map' })).toEqual({
      path: { segments: [{ name: 'Workspace' }, { name: 'Map' }] },
    });
  });

  it('requires at least one addressing field', () => {
    expect(instanceTargetSchema.safeParse({}).success).toBe(false);
    expect(instanceTargetSchema.safeParse({ ref: 'ref_1' }).success).toBe(true);
  });

  it('rejects a malformed ref', () => {
    expect(instanceTargetSchema.safeParse({ ref: 'not-a-ref' }).success).toBe(false);
  });
});

describe('serializer normalisation', () => {
  it('replaces a cyclic structure with a marker instead of throwing', () => {
    const cyclic: Record<string, unknown> = { name: 'root' };
    cyclic.self = cyclic;

    const { value } = normalizeIncoming(cyclic);
    expect(() => JSON.stringify(value)).not.toThrow();
    expect(JSON.stringify(value)).toContain('Cycle');
  });

  it('truncates beyond the depth limit', () => {
    let deep: Record<string, unknown> = { leaf: true };
    for (let index = 0; index < 30; index += 1) deep = { nested: deep };

    const { value, report } = normalizeIncoming(deep, { ...DEFAULT_LIMITS, maxDepth: 4 });
    expect(report.truncated).toBe(true);
    expect(JSON.stringify(value)).toContain('depth-limit');
  });

  it('caps array length and records the omission', () => {
    const { value, report } = normalizeIncoming(
      Array.from({ length: 500 }, (_, index) => index),
      {
        ...DEFAULT_LIMITS,
        maxItems: 10,
      },
    );
    expect(report.truncated).toBe(true);
    expect(Array.isArray(value)).toBe(true);
    expect((value as unknown[]).length).toBe(11); // 10 items plus the truncation marker
  });

  it('caps long strings', () => {
    const { value } = normalizeIncoming('x'.repeat(500), {
      ...DEFAULT_LIMITS,
      maxStringLength: 20,
    });
    expect(String(value)).toContain('truncated');
    expect(String(value).length).toBeLessThan(80);
  });

  it('renders non-finite numbers instead of emitting invalid JSON', () => {
    const { value } = normalizeIncoming({ a: Number.NaN, b: Number.POSITIVE_INFINITY });
    expect(JSON.stringify(value)).toContain('Unsupported');
  });

  it('formats tagged Roblox values deterministically', () => {
    expect(formatValue({ __t: 'Vector3', x: 1, y: 2, z: 3 })).toBe('Vector3(1, 2, 3)');
    expect(formatValue({ __t: 'EnumItem', enumType: 'Material', name: 'Plastic' })).toBe(
      'Enum.Material.Plastic',
    );
    expect(formatValue({ __t: 'Cycle' })).toBe('[cyclic reference]');
    expect(formatValue(null)).toBe('nil');
  });

  it('recognises tagged values and ignores lookalikes', () => {
    expect(isTaggedValue({ __t: 'Vector3' })).toBe(true);
    expect(isTaggedValue({ __t: 'NotAType' })).toBe(false);
    expect(isTaggedValue({ x: 1 })).toBe(false);
  });
});

describe('redaction', () => {
  it('masks credential-shaped values in free text', () => {
    const text = `token crx_${'a'.repeat(43)} and mcp cmc_${'b'.repeat(43)}`;
    const redacted = redactText(text);
    expect(redacted).not.toContain('crx_');
    expect(redacted).not.toContain('cmc_');
    expect(redacted).toContain(REDACTED);
  });

  it('masks a Render API key and a GitHub token', () => {
    expect(redactText(`rnd_${'x'.repeat(30)}`)).toBe(REDACTED);
    expect(redactText(`ghp_${'y'.repeat(36)}`)).toBe(REDACTED);
  });

  it('masks authorization and cookie headers by name', () => {
    const headers = redactHeaders({
      authorization: 'Bearer supersecretvalue',
      cookie: 'clovyre_owner_x=cow_secret',
      'user-agent': 'Clovyre/1.0',
    });
    expect(headers.authorization).toBe(REDACTED);
    expect(headers.cookie).toBe(REDACTED);
    expect(headers['user-agent']).toBe('Clovyre/1.0');
  });

  it('masks sensitive keys anywhere in a nested structure', () => {
    const redacted = redactValue({ nested: { robloxToken: 'crx_secret', safe: 'visible' } });
    expect(JSON.stringify(redacted)).not.toContain('crx_secret');
    expect(JSON.stringify(redacted)).toContain('visible');
  });

  it('abbreviates long previews and reports the omitted length', () => {
    const preview = abbreviate('y'.repeat(1000), 50);
    expect(preview.length).toBeLessThan(90);
    expect(preview).toContain('+950 chars');
  });
});

describe('rate limiting', () => {
  it('permits up to the limit then blocks within the window', () => {
    const limiter = new RateLimiter({ demo: { limit: 3, windowMs: 1000 } });
    const now = Date.now();

    expect(limiter.check('demo', 'key', now).allowed).toBe(true);
    expect(limiter.check('demo', 'key', now).allowed).toBe(true);
    expect(limiter.check('demo', 'key', now).allowed).toBe(true);

    const blocked = limiter.check('demo', 'key', now);
    expect(blocked.allowed).toBe(false);
    expect(blocked.retryAfterMs).toBeGreaterThan(0);
  });

  it('keeps buckets separate per key and recovers after the window', () => {
    const limiter = new RateLimiter({ demo: { limit: 1, windowMs: 1000 } });
    const now = Date.now();

    expect(limiter.check('demo', 'a', now).allowed).toBe(true);
    expect(limiter.check('demo', 'b', now).allowed).toBe(true);
    expect(limiter.check('demo', 'a', now).allowed).toBe(false);
    expect(limiter.check('demo', 'a', now + 1500).allowed).toBe(true);
  });

  it('throws on an unknown rule rather than failing open', () => {
    const limiter = new RateLimiter({ demo: { limit: 1, windowMs: 1000 } });
    expect(() => limiter.check('nope', 'key')).toThrow(/Unknown rate limit rule/);
  });
});

describe('safe property registry', () => {
  it('resolves inherited properties through the class hierarchy', () => {
    const properties = safePropertiesFor('Part');
    expect(properties).toContain('Shape');
    expect(properties).toContain('Anchored');
    expect(properties).toContain('Name');
  });

  it('falls back to Instance properties for an unknown class', () => {
    expect(safePropertiesFor('SomeFutureClass')).toEqual(['Name', 'ClassName', 'Archivable']);
  });

  it('refuses a property that is not registered for the class', () => {
    expect(isSafeProperty('Part', 'Anchored')).toBe(true);
    expect(isSafeProperty('Part', 'Source')).toBe(false);
    expect(isSafeProperty('Folder', 'WalkSpeed')).toBe(false);
  });
});
