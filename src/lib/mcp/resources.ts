import { getSessionBroker } from '../sessions/broker';
import type { SessionRecord } from '../sessions/types';
import { invokeTool } from '../tools/invoke';
import { listCapabilities, sessionInfo } from './local-tools';

/**
 * MCP resources.
 *
 * Resources let a client attach live context directly — in Claude, by mentioning
 * them — rather than spending a tool call to fetch it. Clovyre exposes the small
 * set worth pinning to a conversation: session state, the capability matrix, the
 * service list and a bounded snapshot of the replicated tree.
 *
 * Reading a resource runs the same gated invocation path as the equivalent tool,
 * so nothing here can bypass a capability or privilege check.
 */

export interface ResourceDescriptor {
  readonly uri: string;
  readonly name: string;
  readonly title: string;
  readonly description: string;
  readonly mimeType: string;
}

const STATIC_RESOURCES: readonly ResourceDescriptor[] = Object.freeze([
  {
    uri: 'clovyre://session',
    name: 'session',
    title: 'Session state',
    description:
      'Live connection state for this Clovyre session: Roblox client, place, local player, executor, ' +
      'capabilities and privileges.',
    mimeType: 'application/json',
  },
  {
    uri: 'clovyre://capabilities',
    name: 'capabilities',
    title: 'Client capabilities',
    description: 'Which executor capabilities were reported and which tools each one unlocks.',
    mimeType: 'application/json',
  },
  {
    uri: 'clovyre://services',
    name: 'services',
    title: 'Replicated services',
    description:
      'The Roblox services visible to this client, with child counts. A good starting point for ' +
      'orientation.',
    mimeType: 'application/json',
  },
  {
    uri: 'clovyre://tree',
    name: 'tree',
    title: 'Replicated instance tree (snapshot)',
    description:
      'A depth-limited snapshot of the replicated tree from the DataModel root. Bounded, so treat it ' +
      'as orientation rather than a complete listing.',
    mimeType: 'application/json',
  },
  {
    uri: 'clovyre://scripts',
    name: 'scripts',
    title: 'Replicated scripts',
    description:
      'LocalScripts and replicated ModuleScripts visible to this client, with whether a source ' +
      'representation is obtainable for each.',
    mimeType: 'application/json',
  },
]);

export function listResources(session: SessionRecord): ResourceDescriptor[] {
  // Everything except session state needs a live client to mean anything.
  if (!getSessionBroker().isConnected(session.id)) {
    return STATIC_RESOURCES.filter(
      (resource) =>
        resource.uri === 'clovyre://session' || resource.uri === 'clovyre://capabilities',
    );
  }
  return [...STATIC_RESOURCES];
}

export interface ResourceContents {
  readonly uri: string;
  readonly mimeType: string;
  readonly text: string;
}

/** Reads one resource. Unknown URIs throw so the caller can answer with an error. */
export async function readResource(session: SessionRecord, uri: string): Promise<ResourceContents> {
  const json = (payload: unknown): ResourceContents => ({
    uri,
    mimeType: 'application/json',
    text: JSON.stringify(payload, null, 2),
  });

  switch (uri) {
    case 'clovyre://session':
      return json(sessionInfo(session));

    case 'clovyre://capabilities':
      return json(listCapabilities(session));

    case 'clovyre://services': {
      const result = await invokeTool(session, 'clovyre_get_services', {}, 'mcp');
      return json(result.ok ? result.data : { error: result.code, message: result.message });
    }

    case 'clovyre://tree': {
      const result = await invokeTool(
        session,
        'clovyre_get_instance_tree',
        { displayPath: 'Workspace', maxDepth: 3, maxNodes: 200, childLimitPerNode: 20 },
        'mcp',
      );
      return json(result.ok ? result.data : { error: result.code, message: result.message });
    }

    case 'clovyre://scripts': {
      const result = await invokeTool(
        session,
        'clovyre_list_scripts',
        { maxResults: 200, maxDepth: 8 },
        'mcp',
      );
      return json(result.ok ? result.data : { error: result.code, message: result.message });
    }

    default:
      throw new Error(`Unknown resource: ${uri}`);
  }
}
