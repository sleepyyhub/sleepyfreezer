import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * GET /client.lua
 *
 * Serves the Roblox bridge script. The script carries no credentials: it reads
 * everything it needs from getgenv().ClovyreConfig, which the user pastes above
 * the loadstring. That keeps this endpoint public and cacheable-by-nobody rather
 * than session-specific.
 */

let cached: { source: string; loadedAt: number } | null = null;
const CACHE_TTL_MS = 60_000;

async function loadSource(): Promise<string> {
  if (cached && Date.now() - cached.loadedAt < CACHE_TTL_MS) {
    return cached.source;
  }
  const source = await readFile(join(process.cwd(), 'roblox', 'client.lua'), 'utf8');
  cached = { source, loadedAt: Date.now() };
  return source;
}

export async function GET(): Promise<Response> {
  try {
    const source = await loadSource();
    return new Response(source, {
      status: 200,
      headers: {
        // text/plain so game:HttpGet returns it verbatim on every executor.
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': 'public, max-age=60',
        'x-content-type-options': 'nosniff',
        'x-clovyre-script': 'roblox-bridge',
      },
    });
  } catch {
    return new Response(
      '-- Clovyre could not load the bridge script. Please report this at the Clovyre repository.\n' +
        'error("[Clovyre] The bridge script is unavailable on this deployment.", 0)\n',
      { status: 500, headers: { 'content-type': 'text/plain; charset=utf-8' } },
    );
  }
}
