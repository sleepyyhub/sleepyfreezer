import type { Metadata } from 'next';
import Link from 'next/link';
import { TOOL_DEFINITIONS } from '@/lib/tools/registry';
import { CAPABILITY_NAMES, PROTOCOL_VERSION } from '@/lib/protocol/messages';

export const metadata: Metadata = {
  title: 'Documentation',
  description: 'Architecture, protocol, tools, security model and troubleshooting for Clovyre MCP.',
};

const sections = [
  { id: 'architecture', label: 'Architecture' },
  { id: 'quickstart', label: 'Quick start' },
  { id: 'connect-claude', label: 'Connecting Claude' },
  { id: 'tools', label: 'Tools' },
  { id: 'privileged', label: 'Privileged tools' },
  { id: 'limits', label: 'Limitations' },
  { id: 'security', label: 'Security' },
  { id: 'api', label: 'API reference' },
  { id: 'ws-protocol', label: 'WebSocket protocol' },
  { id: 'mcp-protocol', label: 'MCP protocol' },
  { id: 'deployment', label: 'Deployment' },
  { id: 'env', label: 'Environment' },
  { id: 'troubleshooting', label: 'Troubleshooting' },
];

const environmentVariables = [
  ['NODE_ENV', 'production on Render. Controls cookie security and Next.js mode.'],
  ['PORT', 'Supplied by Render. The server binds to it directly.'],
  ['PUBLIC_BASE_URL', 'Canonical public origin. Falls back to the forwarded host when unset.'],
  [
    'SESSION_SECRET',
    'Salt for address hashing. Generated per boot if unset, which changes the digests on restart.',
  ],
  ['TOKEN_HASH_SECRET', 'HMAC key for credential digests. Generated per boot if unset.'],
  [
    'DATABASE_URL',
    'Postgres connection string. Makes sessions durable across restarts. Unset means in-memory only.',
  ],
  [
    'SESSION_TTL_MINUTES',
    'Session lifetime. Set to 0, the deployment default, for no timed expiry.',
  ],
  [
    'PRIVILEGE_TTL_MINUTES',
    'Lifetime of the Luau, executor-globals and remote-spy grants. Default 0, meaning they stand until turned off.',
  ],
  [
    'MUTATION_PRIVILEGE_TTL_MINUTES',
    'Lifetime of the mutation grant. Default 0, meaning it stands until turned off.',
  ],
  ['MAX_WS_PAYLOAD_BYTES', 'Maximum WebSocket frame size. Default 524288.'],
  ['MAX_COMMAND_TIMEOUT_MS', 'Upper bound on any single command timeout. Default 30000.'],
  ['MAX_SCRIPT_SOURCE_BYTES', 'Upper bound on returned script source. Default 262144.'],
  ['ENABLE_EXECUTE_LUAU_FEATURE', 'Deployment kill switch for Luau execution. Default true.'],
  ['ENABLE_MUTATION_TOOLS_FEATURE', 'Deployment kill switch for mutation tools. Default true.'],
  ['ENABLE_REMOTE_SPY_FEATURE', 'Deployment kill switch for the remote spy. Default true.'],
  ['MAX_SESSIONS', 'Concurrent session ceiling. Default 500.'],
  ['SESSION_CREATE_PER_MINUTE', 'Sessions one client address may create per minute. Default 12.'],
];

const apiRoutes = [
  [
    'GET',
    '/api/health',
    'Service status, version, dependency state and session counts. No authentication.',
  ],
  [
    'POST',
    '/api/sessions',
    'Creates a session. Returns the Roblox and MCP tokens once; sets owner cookies.',
  ],
  ['GET', '/api/sessions/{id}', 'Full dashboard state. Requires the owner cookie.'],
  ['DELETE', '/api/sessions/{id}', 'Terminates the session. Owner cookie plus CSRF header.'],
  [
    'POST',
    '/api/sessions/{id}/privileges',
    'Grants or revokes a privileged capability. Owner only.',
  ],
  ['POST', '/api/sessions/{id}/credentials', 'Revokes one credential by role. Owner only.'],
  [
    'POST',
    '/api/sessions/{id}/credentials/rotate',
    'Issues a fresh Roblox or MCP credential and returns it once. Owner only.',
  ],
  [
    'POST',
    '/api/sessions/{id}/tools',
    'Runs a Clovyre tool as the owner. Same path MCP clients use.',
  ],
  ['POST', '/api/mcp/{id}', 'Remote MCP endpoint. Bearer token authentication.'],
  [
    'POST',
    '/api/mcp/{id}/{token}',
    'Same endpoint, credential in the path, for connector UIs that cannot send headers.',
  ],
  ['GET', '/client.lua', 'The Roblox bridge script. Public and credential-free.'],
  ['—', '/ws/roblox', 'WebSocket gateway. Authenticated by the hello frame, not by headers.'],
];

export default function DocsPage() {
  const byCategory = new Map<string, typeof TOOL_DEFINITIONS>();
  for (const tool of TOOL_DEFINITIONS) {
    byCategory.set(tool.category, [...(byCategory.get(tool.category) ?? []), tool]);
  }

  return (
    <div className="cl-shell cl-rise py-14 sm:py-20">
      <header className="max-w-3xl">
        <p className="cl-label">Documentation</p>
        <h1 className="mt-3 text-[34px] font-semibold leading-tight tracking-[-0.03em] text-ink sm:text-[44px]">
          How Clovyre works, precisely.
        </h1>
        <p className="mt-5 text-[15.5px] leading-relaxed text-ink-muted">
          Clovyre bridges a live Roblox client to an MCP agent through a cloud service. This page
          describes what it can reach, what it cannot, and how each piece is wired together.
        </p>
      </header>

      <nav className="cl-surface mt-10 p-5">
        <div className="cl-label mb-3">Contents</div>
        <div className="flex flex-wrap gap-x-5 gap-y-2 text-[13px]">
          {sections.map((section) => (
            <a key={section.id} href={`#${section.id}`} className="cl-link">
              {section.label}
            </a>
          ))}
        </div>
      </nav>

      <div className="mt-14 flex flex-col gap-14">
        <Section id="architecture" title="Architecture">
          <P>
            Three participants share one session. The Roblox client dials out over a secure
            WebSocket; the MCP agent calls in over HTTPS; the browser dashboard owns the session and
            holds the only credential that can change its configuration.
          </P>
          <Pre>{`Live Roblox client
    |  wss://<deployment>/ws/roblox        (hello frame carries the Roblox token)
    v
Clovyre backend  —  session store · broker · pending commands · audit · limits
    ^
    |  https://<deployment>/api/mcp/<sessionId>   (Authorization: Bearer <MCP token>)
Claude · Claude Code · Codex · other MCP client`}</Pre>
          <P>
            The backend is a single Node process. Next.js serves the dashboard and the API routes;
            the same HTTP server also handles the WebSocket upgrade, which is why Clovyre needs a
            long-lived container rather than serverless functions.
          </P>
          <P>
            A session is what you configure your agent against, so it is written through to Postgres
            on every change and reloaded at boot: a restart or a redeploy does not break your MCP
            configuration. What is deliberately not persisted is anything describing a live
            connection — the WebSocket, pending commands, observation buffers and the audit trail.
            Those describe a process that no longer exists, and they rebuild the moment your Roblox
            client reconnects.
          </P>
        </Section>

        <Section id="quickstart" title="Quick start">
          <Ol
            items={[
              'Open the Clovyre home page and tap Create session.',
              'The dashboard opens with a generated loadstring. Copy it with the copy button.',
              'Lost it? Reload — the dashboard generates a fresh script automatically, because Clovyre stores only credential digests and cannot redisplay the original.',
              'Paste and run the loadstring in your executor while your Roblox experience is open.',
              'The dashboard flips to "Roblox connected" within a second or two, and the capability list fills in.',
              'Copy the MCP endpoint and bearer token into your agent, then start calling tools.',
            ]}
          />
          <P>
            The loadstring sets <Code>getgenv().ClovyreConfig</Code> and then fetches{' '}
            <Code>/client.lua</Code>. The script itself is public and contains no credentials —
            every secret arrives through that config table.
          </P>
          <P>
            Running the loadstring a second time tears down the previous connection before starting
            a new one, so you never end up with two bridges answering the same commands. To stop it
            manually, call <Code>getgenv().ClovyreDisconnect()</Code>.
          </P>
        </Section>

        <Section id="connect-claude" title="Connecting Claude and other MCP clients">
          <P>
            Clovyre speaks MCP over Streamable HTTP. There is one endpoint per session and it
            authenticates with a bearer token bound to that session.
          </P>
          <Ol
            items={[
              'In the Claude app, open Settings, then Connectors, then "Add custom connector".',
              'Paste the connector URL from your session dashboard. It looks like https://<deployment>/api/mcp/<sessionId>/<token> and needs no other fields.',
              'Save. Claude sends initialize, then tools/list, and the available tools appear.',
              'Ask Claude to run clovyre_session_info to confirm the Roblox client is live.',
            ]}
          />
          <Callout tone="alert" title="Why the connector URL carries the credential">
            <P>
              Claude&apos;s custom connector screen accepts a URL and provides no field for an
              authorization header, so Clovyre publishes the endpoint with the token as the final
              path segment. A credential in a URL is visible to proxy and platform access logs, and
              anyone holding that URL can drive the session. It is scoped to one session, expires
              with it, and can be regenerated or revoked from the dashboard at any time. Clients
              that can send headers should use the bearer form instead.
            </P>
          </Callout>
          <P>
            For Claude Code, use the header form instead, which keeps the credential out of the URL:{' '}
            <Code>
              claude mcp add --transport http clovyre &lt;endpoint&gt; --header &quot;Authorization:
              Bearer &lt;token&gt;&quot;
            </Code>
          </P>
          <P>
            For desktop clients that only speak stdio, the dashboard also generates a configuration
            that proxies the same endpoint through <Code>mcp-remote</Code>. The remote HTTP form is
            preferred: it needs no local process at all, which is the point of Clovyre.
          </P>
        </Section>

        <Section id="tools" title="Tools">
          <P>
            Clovyre exposes {TOOL_DEFINITIONS.length} tools. A tool is only offered to your agent
            when the deployment allows it, your executor reports the capability it needs, and — for
            privileged tools — you have granted it in the dashboard.
          </P>
          {[...byCategory.entries()].map(([category, tools]) => (
            <div key={category} className="mt-6">
              <h3 className="text-[14px] font-semibold capitalize text-ink">{category}</h3>
              <div className="mt-3 overflow-hidden rounded-xl border border-line">
                <table className="w-full text-left text-[12.5px]">
                  <tbody>
                    {tools.map((tool) => (
                      <tr
                        key={tool.name}
                        className="border-b border-line last:border-b-0 align-top"
                      >
                        <td className="w-1/3 px-3 py-2.5 font-mono text-[11.5px] text-ink">
                          {tool.name}
                        </td>
                        <td className="px-3 py-2.5 text-ink-muted">
                          {tool.title}
                          {tool.requiresCapability ? (
                            <span className="ml-2 text-ink-faint">
                              requires <Code>{tool.requiresCapability}</Code>
                            </span>
                          ) : null}
                          {tool.requiresPrivilege ? (
                            <span className="ml-2 text-[#ffb4a8]">
                              requires the {tool.requiresPrivilege} grant
                            </span>
                          ) : null}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          ))}
          <P>
            Capabilities probed at startup: {CAPABILITY_NAMES.map((name) => name).join(', ')}. A
            missing capability disables its tools and is not an error.
          </P>
        </Section>

        <Section id="privileged" title="Privileged tools">
          <Callout tone="alert" title="clovyre_execute_luau is dangerous and disabled by default">
            <P>
              Arbitrary Luau running inside your client can modify local state, read anything the
              client can see, call executor-provided functions, and interfere with or crash the
              running game. Only the authenticated browser owner can enable it. An MCP client cannot
              enable it for itself, and there is no API that lets it try.
            </P>
          </Callout>
          <P>
            On this deployment a grant stands until the owner turns it off, so an agent mid-task is
            never cut off by a timer. Revoking is instant and takes effect on the next tool call.
            Every grant and revocation produces an audit event, and a persistent banner stays in the
            dashboard for as long as any privilege is live — the banner is the reminder that a timer
            would otherwise have been. Set a non-zero PRIVILEGE_TTL_MINUTES to get self-clearing
            grants back.
          </P>
          <P>
            A second toggle controls whether executed code sees executor-specific globals. It
            defaults to off, and when off, Clovyre installs a function environment that masks
            well-known executor globals.{' '}
            <strong className="text-ink">This is a convenience filter, not a sandbox.</strong> On
            most executors a determined chunk can still reach the real environment. Clovyre does not
            describe the execution environment as sandboxed, because it is not.
          </P>
          <P>
            Mutation tools (<Code>set_property</Code>, <Code>set_attribute</Code>,{' '}
            <Code>create_instance</Code>, <Code>destroy_instance</Code>,{' '}
            <Code>reparent_instance</Code>) are a separate grant. They change local client state
            only. The Roblox server remains authoritative and will typically ignore or overwrite the
            change; destroying an instance is irreversible for that session.
          </P>
        </Section>

        <Section id="limits" title="Limitations">
          <Ul
            items={[
              'Only state replicated to the live client is reachable. ServerScriptService, ServerStorage, server Scripts and server memory are not, and no amount of tooling changes that.',
              'Decompilation is best effort. Output labelled "decompiled" may differ from the original source or be outright wrong, and Clovyre labels it as such everywhere it appears.',
              'Executor APIs vary widely. Tools that depend on decompile, getgc, getsenv, getconnections or getloadedmodules only appear when your executor actually provides them.',
              'Local mutations do not change server-authoritative state.',
              'Ownership verification is not implemented. Clovyre does not check that you own the experience you connect it to.',
              'A session survives a restart, but the connection to it does not. After a redeploy you rerun the loadstring; your MCP configuration is untouched.',
              'Streamed-out instances lose their references. A ref that pointed at an unstreamed part will report that it is no longer valid.',
            ]}
          />
        </Section>

        <Section id="security" title="Security model">
          <Ul
            items={[
              'Four independent credentials per session: Roblox, MCP, browser owner and CSRF. Each is 256 bits of entropy and only an HMAC-SHA256 digest is retained.',
              'The public session id is an address, never an authenticator. No privileged route accepts it as proof of anything.',
              'Credentials are checked only against the session named in the request, which makes cross-session command routing structurally impossible.',
              'Owner routes require an httpOnly cookie, a matching double-submit CSRF token, and a same-origin request.',
              'Every WebSocket frame is validated with Zod. Unknown message types, oversized payloads and binary frames are rejected.',
              'Commands carry timeouts, concurrency caps and per-session rate limits. Results arriving for unknown or settled commands are discarded.',
              'Audit events, logs and activity views pass through a redaction layer that masks credential-shaped values and sensitive header names.',
              'Secure headers and a Content Security Policy are applied to every response.',
            ]}
          />
          <Callout tone="alert" title="Ownership verification is not enabled">
            <P>
              The architecture has a hook for verifying that a session owner controls the universe
              being inspected, but the check is not implemented in this prototype. Use Clovyre only
              in experiences you own or are explicitly authorised to test.
            </P>
          </Callout>
        </Section>

        <Section id="api" title="API reference">
          <div className="overflow-hidden rounded-xl border border-line">
            <table className="w-full text-left text-[12.5px]">
              <tbody>
                {apiRoutes.map(([method, path, description]) => (
                  <tr key={path} className="border-b border-line last:border-b-0 align-top">
                    <td className="w-16 px-3 py-2.5 font-mono text-[11.5px] text-clover-300">
                      {method}
                    </td>
                    <td className="w-1/3 px-3 py-2.5 font-mono text-[11.5px] text-ink">{path}</td>
                    <td className="px-3 py-2.5 text-ink-muted">{description}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Section>

        <Section id="ws-protocol" title="WebSocket protocol">
          <P>
            Every frame is UTF-8 JSON carrying{' '}
            <Code>protocolVersion: {String(PROTOCOL_VERSION)}</Code> and a <Code>type</Code>.
            Authentication happens in the first frame because executor WebSocket APIs cannot set
            request headers.
          </P>
          <P className="mt-4">
            Client to server: <Code>hello</Code>, <Code>heartbeat</Code>, <Code>result</Code>,{' '}
            <Code>event</Code>, <Code>log</Code>, <Code>capabilities_update</Code>,{' '}
            <Code>goodbye</Code>.
          </P>
          <P>
            Server to client: <Code>hello_ack</Code>, <Code>command</Code>,{' '}
            <Code>cancel_command</Code>, <Code>session_revoked</Code>, <Code>session_expired</Code>,{' '}
            <Code>heartbeat_ack</Code>, <Code>error</Code>.
          </P>
          <Pre>{`// server -> client
{
  "protocolVersion": 1,
  "type": "command",
  "id": "cmd_unique_id",
  "tool": "clovyre_inspect_instance",
  "arguments": { "displayPath": "ReplicatedStorage.Controllers" },
  "timeoutMs": 15000
}

// client -> server, success
{ "protocolVersion": 1, "type": "result", "id": "cmd_unique_id", "ok": true, "result": {} }

// client -> server, failure
{
  "protocolVersion": 1,
  "type": "result",
  "id": "cmd_unique_id",
  "ok": false,
  "error": { "code": "INSTANCE_NOT_FOUND", "message": "The requested instance is unavailable." }
}`}</Pre>
          <P>
            Instances are addressed with structured paths rather than dot-joined strings, because
            Roblox names may contain dots. A path is an ordered list of{' '}
            <Code>{'{ name, className }'}</Code> segments; a readable display path is provided
            alongside it, with dots inside names escaped as <Code>\.</Code>. Session-scoped refs
            such as <Code>ref_12</Code> are cheaper and survive renames.
          </P>
        </Section>

        <Section id="mcp-protocol" title="MCP protocol">
          <P>
            Transport is Streamable HTTP: JSON-RPC 2.0 over POST, answered with{' '}
            <Code>application/json</Code>. Clovyre has no server-initiated messages, so it does not
            open SSE streams and declines GET on the endpoint with an explanatory 405.
          </P>
          <P>
            Supported methods: <Code>initialize</Code>, <Code>ping</Code>, <Code>tools/list</Code>,{' '}
            <Code>tools/call</Code>, <Code>resources/list</Code>, <Code>prompts/list</Code>, plus
            the standard notifications. Tool failures come back as successful JSON-RPC responses
            with <Code>isError: true</Code> and a structured code, so the agent can reason about
            them.
          </P>
          <Pre>{`curl -sS https://<deployment>/api/mcp/<sessionId> \\
  -H 'Authorization: Bearer <MCP token>' \\
  -H 'content-type: application/json' \\
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'`}</Pre>
        </Section>

        <Section id="deployment" title="Render deployment">
          <P>
            Clovyre deploys as a single Render web service running a Node process. The service must
            hold long-lived WebSocket connections, so serverless targets are not usable.
          </P>
          <Ul
            items={[
              'Build: npm ci --include=dev && npm run build — Render sets NODE_ENV=production, which would otherwise make npm ci skip the devDependencies the build needs.',
              'Start: npm start — runs the compiled server, which binds to process.env.PORT.',
              'Health check path: /api/health.',
              'Instance count: one. Session state is in-process, so a second instance would not see the first instance sessions.',
              'Scaling beyond one instance requires a shared broker (Redis or equivalent) for session routing.',
            ]}
          />
        </Section>

        <Section id="env" title="Environment variables">
          <div className="overflow-hidden rounded-xl border border-line">
            <table className="w-full text-left text-[12.5px]">
              <tbody>
                {environmentVariables.map(([name, description]) => (
                  <tr key={name} className="border-b border-line last:border-b-0 align-top">
                    <td className="w-1/3 px-3 py-2.5 font-mono text-[11.5px] text-ink">{name}</td>
                    <td className="px-3 py-2.5 text-ink-muted">{description}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <P>
            No secret is ever exposed to the browser bundle. There are no <Code>NEXT_PUBLIC_</Code>{' '}
            variables in Clovyre, by design.
          </P>
        </Section>

        <Section id="troubleshooting" title="Troubleshooting">
          <Trouble
            problem="The loadstring errors with “does not expose a WebSocket connect function”."
            answer="Your executor does not provide WebSocket.connect, websocket.connect or syn.websocket.connect. Clovyre cannot run without one; there is no fallback transport."
          />
          <Trouble
            problem="The dashboard stays on “Roblox not connected”."
            answer="Check that the session has not expired, that the Roblox credential has not been revoked, and that you copied the entire loadstring including the config table above it. The activity tab records every rejected handshake and the reason."
          />
          <Trouble
            problem="A tool returns CAPABILITY_UNAVAILABLE."
            answer="Your executor did not report the function that tool needs. The overview tab lists exactly which capabilities were found."
          />
          <Trouble
            problem="A tool returns PRIVILEGE_REQUIRED."
            answer="That tool needs a grant you have not made. Enable it under Privileged capabilities on the overview tab; the grant expires on its own."
          />
          <Trouble
            problem="A command times out."
            answer="The client did not answer in time — usually a very large subtree. Narrow the request with a lower maxDepth, maxResults or limit."
          />
          <Trouble
            problem="A result comes back as PAYLOAD_TOO_LARGE."
            answer="The serialized answer exceeded the frame limit. Request a smaller page, a shallower tree, or a more specific target."
          />
          <Trouble
            problem="Everything stopped working at once."
            answer="The session was terminated, or the deployment runs without DATABASE_URL and lost its sessions on restart. If the session is still listed but tools fail, the Roblox client is simply disconnected — rerun the loadstring."
          />
          <Trouble
            problem="An instance ref stopped resolving."
            answer="The instance was destroyed or streamed out. Re-resolve it by path, or re-run the search that produced it."
          />
        </Section>
      </div>

      <div className="cl-surface mt-16 p-6">
        <p className="text-[13px] text-ink-muted">
          Ready to try it?{' '}
          <Link href="/#start" className="cl-link">
            Create a session
          </Link>{' '}
          — it takes one tap and expires by itself.
        </p>
      </div>
    </div>
  );
}

function Section({
  id,
  title,
  children,
}: {
  id: string;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section id={id} className="scroll-mt-24">
      <h2 className="text-[24px] font-semibold leading-tight text-ink sm:text-[28px]">{title}</h2>
      <div className="mt-5 max-w-3xl">{children}</div>
    </section>
  );
}

function P({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return (
    <p className={`mt-4 text-[14.5px] leading-relaxed text-ink-muted first:mt-0 ${className}`}>
      {children}
    </p>
  );
}

function Code({ children }: { children: React.ReactNode }) {
  return (
    <code className="rounded-md border border-line bg-base-800/70 px-1.5 py-0.5 text-[12px] text-ink">
      {children}
    </code>
  );
}

function Pre({ children }: { children: string }) {
  return (
    <pre className="cl-code cl-scroll mt-5 whitespace-pre">
      <code>{children}</code>
    </pre>
  );
}

function Ul({ items }: { items: string[] }) {
  return (
    <ul className="mt-4 flex flex-col gap-2.5">
      {items.map((item) => (
        <li key={item} className="flex gap-3 text-[14.5px] leading-relaxed text-ink-muted">
          <span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-clover-400" />
          <span>{item}</span>
        </li>
      ))}
    </ul>
  );
}

function Ol({ items }: { items: string[] }) {
  return (
    <ol className="mt-4 flex flex-col gap-2.5">
      {items.map((item, index) => (
        <li key={item} className="flex gap-3 text-[14.5px] leading-relaxed text-ink-muted">
          <span className="font-mono text-[12px] text-clover-300">
            {String(index + 1).padStart(2, '0')}
          </span>
          <span>{item}</span>
        </li>
      ))}
    </ol>
  );
}

function Callout({
  title,
  children,
  tone,
}: {
  title: string;
  children: React.ReactNode;
  tone: 'alert' | 'info';
}) {
  return (
    <div
      className={`mt-5 rounded-xl border p-5 ${
        tone === 'alert'
          ? 'border-[rgba(255,138,120,0.3)] bg-[rgba(255,96,74,0.06)]'
          : 'border-line bg-base-800/40'
      }`}
    >
      <p
        className={`text-[13.5px] font-semibold ${tone === 'alert' ? 'text-[#ffb4a8]' : 'text-ink'}`}
      >
        {title}
      </p>
      <div className="mt-2">{children}</div>
    </div>
  );
}

function Trouble({ problem, answer }: { problem: string; answer: string }) {
  return (
    <div className="mt-4 rounded-xl border border-line bg-base-800/40 p-4">
      <p className="text-[13.5px] font-medium text-ink">{problem}</p>
      <p className="mt-1.5 text-[13px] leading-relaxed text-ink-muted">{answer}</p>
    </div>
  );
}
