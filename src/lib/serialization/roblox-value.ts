import { z } from 'zod';

/**
 * Wire representation of Roblox values.
 *
 * The Roblox bridge tags every non-primitive value with `__t` so the type survives
 * JSON encoding. This module defines that contract, validates incoming values, and
 * renders them for display. The heavy lifting (cycle detection, depth and item
 * limits) happens on the client, in roblox/client.lua; the server re-validates and
 * re-applies limits because the client is untrusted input.
 */

export const SERIALIZED_TYPES = [
  'Vector2',
  'Vector3',
  'CFrame',
  'Color3',
  'BrickColor',
  'UDim',
  'UDim2',
  'Rect',
  'NumberRange',
  'NumberSequence',
  'ColorSequence',
  'Enum',
  'EnumItem',
  'Instance',
  'Ray',
  'Region3',
  'TweenInfo',
  'DateTime',
  'Buffer',
  'Axes',
  'Faces',
  'PhysicalProperties',
  'Font',
  'Unsupported',
  'Truncated',
  'Cycle',
] as const;

export type SerializedTypeName = (typeof SERIALIZED_TYPES)[number];

const num = z.number();

/**
 * Tagged value schema. `passthrough` is intentional: forward compatibility means a
 * newer bridge may add fields the current server does not model yet.
 */
export const taggedValueSchema = z.object({ __t: z.enum(SERIALIZED_TYPES) }).passthrough();

export type TaggedValue = z.infer<typeof taggedValueSchema> & Record<string, unknown>;

export function isTaggedValue(value: unknown): value is TaggedValue {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as { __t?: unknown }).__t === 'string' &&
    (SERIALIZED_TYPES as readonly string[]).includes((value as { __t: string }).__t)
  );
}

/* ------------------------------------------------------------------ */
/* Limits                                                              */
/* ------------------------------------------------------------------ */

export interface SerializationLimits {
  readonly maxDepth: number;
  readonly maxItems: number;
  readonly maxStringLength: number;
  readonly maxTotalNodes: number;
}

export const DEFAULT_LIMITS: SerializationLimits = {
  maxDepth: 8,
  maxItems: 200,
  maxStringLength: 8192,
  maxTotalNodes: 5000,
};

export interface NormalizeReport {
  truncated: boolean;
  nodes: number;
}

/**
 * Re-applies structural limits to a value received from the Roblox client.
 * Returns a plain JSON-safe structure plus a report of whether anything was cut.
 */
export function normalizeIncoming(
  value: unknown,
  limits: SerializationLimits = DEFAULT_LIMITS,
): { value: unknown; report: NormalizeReport } {
  const report: NormalizeReport = { truncated: false, nodes: 0 };
  const seen = new WeakSet<object>();

  const walk = (input: unknown, depth: number): unknown => {
    report.nodes += 1;
    if (report.nodes > limits.maxTotalNodes) {
      report.truncated = true;
      return { __t: 'Truncated', reason: 'node-limit' };
    }
    if (input === null || input === undefined) return null;

    const kind = typeof input;
    if (kind === 'boolean') return input;
    if (kind === 'number') {
      const asNumber = input as number;
      // JSON has no representation for these; keep them legible instead.
      return Number.isFinite(asNumber)
        ? asNumber
        : { __t: 'Unsupported', reason: String(asNumber) };
    }
    if (kind === 'string') {
      const text = input as string;
      if (text.length <= limits.maxStringLength) return text;
      report.truncated = true;
      return `${text.slice(0, limits.maxStringLength)}…[truncated ${text.length - limits.maxStringLength} chars]`;
    }
    if (kind !== 'object') {
      return { __t: 'Unsupported', reason: kind };
    }

    const objectInput = input as object;
    if (seen.has(objectInput)) {
      return { __t: 'Cycle' };
    }
    if (depth >= limits.maxDepth) {
      report.truncated = true;
      return { __t: 'Truncated', reason: 'depth-limit' };
    }
    seen.add(objectInput);

    try {
      if (Array.isArray(input)) {
        const items = input.slice(0, limits.maxItems).map((item) => walk(item, depth + 1));
        if (input.length > limits.maxItems) {
          report.truncated = true;
          items.push({
            __t: 'Truncated',
            reason: 'item-limit',
            omitted: input.length - limits.maxItems,
          });
        }
        return items;
      }

      const out: Record<string, unknown> = {};
      let count = 0;
      for (const [key, entry] of Object.entries(input as Record<string, unknown>)) {
        if (count >= limits.maxItems) {
          report.truncated = true;
          out.__truncated = true;
          break;
        }
        out[key] = walk(entry, depth + 1);
        count += 1;
      }
      return out;
    } finally {
      seen.delete(objectInput);
    }
  };

  return { value: walk(value, 0), report };
}

/* ------------------------------------------------------------------ */
/* Display                                                             */
/* ------------------------------------------------------------------ */

const round = (value: unknown, places = 3): string => {
  const parsed = num.safeParse(value);
  if (!parsed.success) return '?';
  const factor = 10 ** places;
  return String(Math.round(parsed.data * factor) / factor);
};

const field = (value: TaggedValue, key: string): unknown => value[key];

/**
 * Renders a tagged value as a short, deterministic string for tables and detail
 * panes. Returns null when the input is not a tagged Roblox value.
 */
export function formatTaggedValue(value: TaggedValue): string {
  switch (value.__t) {
    case 'Vector2':
      return `Vector2(${round(field(value, 'x'))}, ${round(field(value, 'y'))})`;
    case 'Vector3':
      return `Vector3(${round(field(value, 'x'))}, ${round(field(value, 'y'))}, ${round(field(value, 'z'))})`;
    case 'CFrame': {
      const position = field(value, 'position');
      if (Array.isArray(position) && position.length >= 3) {
        return `CFrame(pos ${position
          .slice(0, 3)
          .map((n) => round(n))
          .join(', ')})`;
      }
      return 'CFrame(…)';
    }
    case 'Color3': {
      const [r, g, b] = [field(value, 'r'), field(value, 'g'), field(value, 'b')];
      return `Color3(${round(r)}, ${round(g)}, ${round(b)})`;
    }
    case 'BrickColor':
      return `BrickColor("${String(field(value, 'name') ?? 'unknown')}")`;
    case 'UDim':
      return `UDim(${round(field(value, 'scale'))}, ${round(field(value, 'offset'), 0)})`;
    case 'UDim2':
      return `UDim2(${round(field(value, 'xScale'))}, ${round(field(value, 'xOffset'), 0)}, ${round(
        field(value, 'yScale'),
      )}, ${round(field(value, 'yOffset'), 0)})`;
    case 'Rect':
      return `Rect(${round(field(value, 'minX'))}, ${round(field(value, 'minY'))}, ${round(
        field(value, 'maxX'),
      )}, ${round(field(value, 'maxY'))})`;
    case 'NumberRange':
      return `NumberRange(${round(field(value, 'min'))}, ${round(field(value, 'max'))})`;
    case 'NumberSequence': {
      const keypoints = field(value, 'keypoints');
      const count = Array.isArray(keypoints) ? keypoints.length : 0;
      return `NumberSequence(${count} keypoints)`;
    }
    case 'ColorSequence': {
      const keypoints = field(value, 'keypoints');
      const count = Array.isArray(keypoints) ? keypoints.length : 0;
      return `ColorSequence(${count} keypoints)`;
    }
    case 'Enum':
      return `Enum.${String(field(value, 'name') ?? '?')}`;
    case 'EnumItem':
      return `Enum.${String(field(value, 'enumType') ?? '?')}.${String(field(value, 'name') ?? '?')}`;
    case 'Instance': {
      const path = field(value, 'displayPath');
      const className = String(field(value, 'className') ?? 'Instance');
      const name = String(field(value, 'name') ?? '?');
      return typeof path === 'string' && path.length > 0
        ? `${className} @ ${path}`
        : `${className} "${name}"`;
    }
    case 'Ray':
      return 'Ray(origin, direction)';
    case 'Region3':
      return 'Region3(min, max)';
    case 'TweenInfo':
      return `TweenInfo(${round(field(value, 'time'))}s, ${String(field(value, 'easingStyle') ?? '?')})`;
    case 'DateTime':
      return `DateTime(${String(field(value, 'iso') ?? field(value, 'unixTimestampMillis') ?? '?')})`;
    case 'Buffer':
      return `buffer(${round(field(value, 'length'), 0)} bytes)`;
    case 'Axes':
    case 'Faces':
    case 'PhysicalProperties':
    case 'Font':
      return `${value.__t}(${String(field(value, 'summary') ?? '…')})`;
    case 'Cycle':
      return '[cyclic reference]';
    case 'Truncated':
      return `[truncated: ${String(field(value, 'reason') ?? 'limit')}]`;
    case 'Unsupported':
      return `[unsupported: ${String(field(value, 'reason') ?? 'unknown type')}]`;
    default:
      return '[unknown]';
  }
}

/** Renders any decoded value — primitive, tagged or container — for display. */
export function formatValue(value: unknown, depth = 0): string {
  if (value === null || value === undefined) return 'nil';
  if (typeof value === 'boolean' || typeof value === 'number') return String(value);
  if (typeof value === 'string') return value;
  if (isTaggedValue(value)) return formatTaggedValue(value);
  if (Array.isArray(value)) {
    if (depth >= 2) return `[${value.length} items]`;
    return `[${value
      .slice(0, 6)
      .map((item) => formatValue(item, depth + 1))
      .join(', ')}${value.length > 6 ? `, …+${value.length - 6}` : ''}]`;
  }
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>);
    if (depth >= 2) return `{${entries.length} fields}`;
    return `{${entries
      .slice(0, 5)
      .map(([key, entry]) => `${key}: ${formatValue(entry, depth + 1)}`)
      .join(', ')}${entries.length > 5 ? ', …' : ''}}`;
  }
  return String(value);
}
