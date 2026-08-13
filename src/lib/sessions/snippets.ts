/**
 * Copyable snippets shown on the dashboard: the Roblox loadstring and the remote
 * MCP client configuration.
 *
 * These are generated on the server so the token appears in exactly one response
 * and is never reconstructed from anything persisted in the browser.
 */

/**
 * The bootstrap a user pastes into their executor.
 *
 * The obvious one-liner — `loadstring(game:HttpGet(url))()` — assumes two
 * globals that a good number of executors do not provide. `loadstring` is absent
 * wherever the Lua 5.2+ name `load` is used instead, and `game:HttpGet` is absent
 * on executors that expose only a `request`-style function. Either gap surfaces
 * as "attempt to call a nil value" on the bootstrap line, which tells the user
 * nothing about which global was missing.
 *
 * So the bootstrap resolves both at runtime and fails with a sentence naming the
 * thing that was not there.
 */
export function buildLoadstring(baseUrl: string, sessionId: string, robloxToken: string): string {
  return [
    'getgenv().ClovyreConfig = {',
    `    BaseUrl = "${baseUrl}",`,
    `    SessionId = "${sessionId}",`,
    `    RobloxToken = "${robloxToken}"`,
    '}',
    '',
    `local url = "${baseUrl}/client.lua"`,
    'local compile = loadstring or load',
    'assert(compile, "Clovyre: this executor provides neither loadstring nor load.")',
    '',
    'local function fetch()',
    '    local ok, body = pcall(function() return game:HttpGet(url) end)',
    '    if ok and type(body) == "string" and #body > 0 then return body end',
    '    local req = (syn and syn.request) or http_request or request',
    '    if req then',
    '        local res = req({ Url = url, Method = "GET" })',
    '        return res and (res.Body or res.body)',
    '    end',
    '    error("Clovyre: this executor exposes no usable HTTP function (tried game:HttpGet and request).")',
    'end',
    '',
    'local source = fetch()',
    'assert(type(source) == "string" and #source > 0, "Clovyre: the bridge script came back empty.")',
    '',
    'local chunk, err = compile(source, "=clovyre")',
    'assert(chunk, "Clovyre: the bridge script failed to compile: " .. tostring(err))',
    'chunk()',
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
