/**
 * Copyable snippets shown on the dashboard: the Roblox loadstring and the remote
 * MCP client configuration.
 *
 * These are generated on the server so the token appears in exactly one response
 * and is never reconstructed from anything persisted in the browser.
 */

/** The loadstring a user pastes into their executor. */
export function buildLoadstring(baseUrl: string, sessionId: string, robloxToken: string): string {
  return [
    'getgenv().ClovyreConfig = {',
    `    BaseUrl = "${baseUrl}",`,
    `    SessionId = "${sessionId}",`,
    `    RobloxToken = "${robloxToken}"`,
    '}',
    `loadstring(game:HttpGet("${baseUrl}/client.lua"))()`,
  ].join('\n');
}

export interface McpConfigSnippets {
  readonly url: string;
  /**
   * Same endpoint with the credential in the path, for connector UIs that accept
   * only a URL and cannot attach an Authorization header.
   */
  readonly connectorUrl: string;
  readonly authorizationHeader: string;
  /** Ready-to-paste Claude Code CLI command. */
  readonly claudeCodeCommand: string;
  /** Config for clients that accept a remote URL plus headers. */
  readonly remoteJson: string;
  /** Config for desktop clients that proxy a remote server through a local stdio bridge. */
  readonly proxyJson: string;
}

/**
 * Snippets for the persistent agent link: one URL, configured once, valid across
 * every future session.
 */
export function buildAgentLinkSnippets(baseUrl: string, linkToken: string) {
  const url = `${baseUrl}/api/mcp/link/${linkToken}`;
  return {
    url,
    remoteJson: JSON.stringify({ mcpServers: { clovyre: { type: 'http', url } } }, null, 2),
    claudeCodeCommand: `claude mcp add --transport http clovyre ${url}`,
    proxyJson: JSON.stringify(
      { mcpServers: { clovyre: { command: 'npx', args: ['-y', 'mcp-remote', url] } } },
      null,
      2,
    ),
  };
}

export function buildMcpConfigSnippets(
  baseUrl: string,
  sessionId: string,
  mcpToken: string,
): McpConfigSnippets {
  const url = `${baseUrl}/api/mcp/${sessionId}`;
  const connectorUrl = `${url}/${mcpToken}`;

  const remoteJson = JSON.stringify(
    {
      mcpServers: {
        clovyre: {
          type: 'http',
          url,
          headers: { Authorization: `Bearer ${mcpToken}` },
        },
      },
    },
    null,
    2,
  );

  const proxyJson = JSON.stringify(
    {
      mcpServers: {
        clovyre: {
          command: 'npx',
          args: ['-y', 'mcp-remote', url, '--header', `Authorization: Bearer ${mcpToken}`],
        },
      },
    },
    null,
    2,
  );

  return {
    url,
    connectorUrl,
    authorizationHeader: `Bearer ${mcpToken}`,
    claudeCodeCommand: `claude mcp add --transport http clovyre ${url} --header "Authorization: Bearer ${mcpToken}"`,
    remoteJson,
    proxyJson,
  };
}
