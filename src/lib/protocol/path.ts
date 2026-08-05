import { z } from 'zod';

/**
 * Structured instance addressing.
 *
 * Roblox instance names may contain dots, quotes and other characters that make
 * a dot-joined string ambiguous, so the wire format is always an ordered list of
 * segments. A human-readable display path is derived from it for the UI only.
 */

export const pathSegmentSchema = z.object({
  name: z.string().max(256),
  className: z.string().max(128).optional(),
});

export type PathSegment = z.infer<typeof pathSegmentSchema>;

export const instancePathSchema = z.object({
  segments: z.array(pathSegmentSchema).max(64),
});

export type InstancePath = z.infer<typeof instancePathSchema>;

/**
 * A session-scoped opaque handle issued by the Roblox client (e.g. "ref_41").
 * Handles survive renames and are cheaper than re-walking a path.
 */
export const instanceRefSchema = z
  .string()
  .regex(/^ref_[A-Za-z0-9]{1,32}$/, 'Instance references look like "ref_12"');

/**
 * Every instance-addressing tool accepts either a structured path or a handle.
 * At least one must be present.
 */
export const targetShape = {
  ref: instanceRefSchema.optional(),
  path: instancePathSchema.optional(),
  /**
   * Convenience form for humans and agents. Split on unescaped dots; a literal
   * dot inside a name is written as "\.".
   */
  displayPath: z.string().max(2048).optional(),
} as const;

export const instanceTargetSchema = z
  .object({ ...targetShape })
  .refine(
    (value) => Boolean(value.ref ?? value.path ?? value.displayPath),
    'Provide "ref", "path" or "displayPath" to identify the instance.',
  );

export type InstanceTarget = z.infer<typeof instanceTargetSchema>;

const NEEDS_ESCAPE = /[.\\]/;

/** Escapes a single segment name for display-path rendering. */
export function escapeSegment(name: string): string {
  if (!NEEDS_ESCAPE.test(name)) return name;
  return name.replace(/\\/g, '\\\\').replace(/\./g, '\\.');
}

/** Renders a structured path as an escaped, dot-joined display string. */
export function formatDisplayPath(path: InstancePath): string {
  return path.segments.map((segment) => escapeSegment(segment.name)).join('.');
}

/** Parses a display path back into segments, honouring backslash escapes. */
export function parseDisplayPath(input: string): InstancePath {
  const segments: PathSegment[] = [];
  let current = '';
  let escaping = false;
  for (const char of input) {
    if (escaping) {
      current += char;
      escaping = false;
      continue;
    }
    if (char === '\\') {
      escaping = true;
      continue;
    }
    if (char === '.') {
      segments.push({ name: current });
      current = '';
      continue;
    }
    current += char;
  }
  segments.push({ name: current });
  return { segments: segments.filter((segment, index) => segment.name !== '' || index === 0) };
}

/**
 * Normalises any accepted target form into what the Roblox client receives.
 * Returns the target unchanged when a handle is present, since handles are the
 * cheapest resolution path on the client.
 */
export function normalizeTarget(target: InstanceTarget): {
  ref?: string;
  path?: InstancePath;
} {
  if (target.ref) return { ref: target.ref };
  if (target.path) return { path: target.path };
  if (target.displayPath) return { path: parseDisplayPath(target.displayPath) };
  // instanceTargetSchema guarantees one of the branches above.
  throw new Error('Instance target is empty.');
}

/** Human-facing rendering of any target form, used in audit lines. */
export function describeTarget(target: InstanceTarget): string {
  if (target.ref) return target.ref;
  if (target.path) return formatDisplayPath(target.path);
  return target.displayPath ?? '(unspecified)';
}
