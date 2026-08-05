import Link from 'next/link';
import { CreateSessionButton } from '@/components/create-session';
import { HealthPill } from '@/components/health-pill';
import { ClovyreMark } from '@/components/brand';
import { TOOL_DEFINITIONS } from '@/lib/tools/registry';

const architecture = [
  {
    step: '01',
    title: 'Live Roblox client',
    body:
      'You paste a generated loadstring into your executor. The Clovyre bridge connects out over a secure ' +
      'WebSocket and reports which executor functions it actually found.',
  },
  {
    step: '02',
    title: 'Clovyre cloud backend',
    body:
      'A single Node service holds the socket, brokers commands, enforces payload and time limits, and keeps ' +
      'a redacted audit trail for the life of the session.',
  },
  {
    step: '03',
    title: 'Your MCP agent',
    body:
      'Claude, Claude Code, Codex or any Streamable HTTP MCP client connects to a per-session endpoint with a ' +
      'bearer token and calls the tools the connected client can actually support.',
  },
];

const capabilities = [
  {
    title: 'Replicated instance explorer',
    body: 'Paginated children, depth-limited trees, name search and class filters over what the client can see.',
  },
  {
    title: 'Safe property reads',
    body: 'A curated per-class registry, read through protected calls, with unavailable properties reported honestly.',
  },
  {
    title: 'Script inspection',
    body: 'LocalScripts and replicated ModuleScripts, labelled as source, decompiled, bytecode-only or unavailable.',
  },
  {
    title: 'Runtime state',
    body: 'Players, local player, character, camera and a bounded workspace summary — plus logs the bridge captured.',
  },
  {
    title: 'Capability-aware tools',
    body: 'Decompilers, getgc, getsenv and getconnections appear only when your executor genuinely provides them.',
  },
  {
    title: 'Audited activity',
    body: 'Every command, duration and failure is recorded per session, with secrets redacted before they are stored.',
  },
];

const security = [
  {
    title: 'Four separate credentials',
    body:
      'The Roblox token, the MCP token, the browser owner token and the CSRF token are independent. Revoke any ' +
      'one without touching the others. Only hashes are kept in memory.',
  },
  {
    title: 'Privileged tools are off',
    body:
      'Luau execution and mutation tools start disabled. Only the authenticated browser owner can enable them, ' +
      'the grant expires by itself, and an MCP client can never enable it for you.',
  },
  {
    title: 'Temporary by design',
    body:
      'Sessions expire on a timer and hold nothing durable. A restart of the service ends every session — that ' +
      'is the intended behaviour, not a defect.',
  },
  {
    title: 'Client-visible scope only',
    body:
      'Server Scripts, ServerScriptService, ServerStorage and server memory are not replicated to a client and ' +
      'are therefore unreachable. Clovyre never claims otherwise.',
  },
];

export default function LandingPage() {
  const readOnlyCount = TOOL_DEFINITIONS.filter((tool) => tool.readOnly).length;
  const privilegedCount = TOOL_DEFINITIONS.filter((tool) => tool.requiresPrivilege).length;

  return (
    <div className="pb-4">
      {/* Hero */}
      <section className="cl-shell pt-16 sm:pt-24">
        <div className="cl-rise max-w-3xl">
          <HealthPill />
          <h1 className="mt-7 text-[40px] font-semibold leading-[1.05] tracking-[-0.03em] text-ink sm:text-[58px]">
            Give your AI agent
            <span className="block text-clover-300">eyes inside a live Roblox client.</span>
          </h1>
          <p className="mt-6 max-w-2xl text-[16px] leading-relaxed text-ink-muted sm:text-[17px]">
            Clovyre MCP is a cloud bridge. Your executor connects out over a secure WebSocket; your
            agent connects in over a remote MCP endpoint. Everything runs in the browser and the
            cloud — no Studio, no local server, no terminal. It works from an iPad.
          </p>

          <div id="start" className="mt-9 flex flex-col gap-3 sm:flex-row sm:items-center">
            <CreateSessionButton className="cl-btn-primary w-full sm:w-auto" />
            <Link href="/docs" className="cl-btn-ghost w-full justify-center sm:w-auto">
              Read the documentation
            </Link>
          </div>

          <p className="mt-5 text-[12.5px] text-ink-faint">
            Sessions are temporary and expire automatically. Connect Clovyre only to experiences you
            own or are authorised to test.
          </p>
        </div>
      </section>

      {/* Architecture */}
      <section className="cl-shell mt-24 sm:mt-32">
        <div className="max-w-2xl">
          <p className="cl-label">Architecture</p>
          <h2 className="mt-3 text-[28px] font-semibold leading-tight text-ink sm:text-[34px]">
            Three participants, one session, four credentials.
          </h2>
          <p className="mt-4 text-[15px] leading-relaxed text-ink-muted">
            A Clovyre session is the only thing that binds the three sides together. Each side
            authenticates with its own secret, and each secret can be revoked on its own.
          </p>
        </div>

        <div className="mt-10 grid gap-4 md:grid-cols-3">
          {architecture.map((item) => (
            <article key={item.step} className="cl-surface p-6">
              <div className="flex items-center gap-3">
                <span className="font-mono text-[12px] text-clover-300">{item.step}</span>
                <span className="h-px flex-1 bg-line" />
              </div>
              <h3 className="mt-4 text-[15px] font-semibold text-ink">{item.title}</h3>
              <p className="mt-2.5 text-[13.5px] leading-relaxed text-ink-muted">{item.body}</p>
            </article>
          ))}
        </div>

        {/* Flow diagram, drawn with layout rather than an image asset. */}
        <div className="cl-surface mt-4 overflow-hidden">
          <div className="cl-scroll px-5 py-6 sm:px-8">
            <div className="flex min-w-[560px] items-center gap-4">
              <FlowNode label="Roblox client" detail="Executor bridge" />
              <FlowEdge label="wss://" />
              <FlowNode label="Clovyre backend" detail="Broker · audit · limits" accent />
              <FlowEdge label="https:// MCP" />
              <FlowNode label="Your agent" detail="Claude · Codex · other" />
            </div>
          </div>
        </div>
      </section>

      {/* Capabilities */}
      <section className="cl-shell mt-24 sm:mt-32">
        <div className="max-w-2xl">
          <p className="cl-label">Capabilities</p>
          <h2 className="mt-3 text-[28px] font-semibold leading-tight text-ink sm:text-[34px]">
            {TOOL_DEFINITIONS.length} tools, {readOnlyCount} of them read-only.
          </h2>
          <p className="mt-4 text-[15px] leading-relaxed text-ink-muted">
            Tools are offered based on what your executor actually reports. The remaining{' '}
            {privilegedCount} privileged tools stay hidden from your agent until you switch them on
            yourself.
          </p>
        </div>

        <div className="mt-10 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {capabilities.map((item) => (
            <article key={item.title} className="cl-surface p-5">
              <h3 className="text-[14px] font-semibold text-ink">{item.title}</h3>
              <p className="mt-2 text-[13px] leading-relaxed text-ink-muted">{item.body}</p>
            </article>
          ))}
        </div>
      </section>

      {/* Security */}
      <section className="cl-shell mt-24 sm:mt-32">
        <div className="max-w-2xl">
          <p className="cl-label">Security model</p>
          <h2 className="mt-3 text-[28px] font-semibold leading-tight text-ink sm:text-[34px]">
            Least privilege, stated plainly.
          </h2>
        </div>

        <div className="mt-10 grid gap-4 sm:grid-cols-2">
          {security.map((item) => (
            <article key={item.title} className="cl-surface p-6">
              <div className="flex items-start gap-3.5">
                <ClovyreMark size={18} className="mt-0.5 shrink-0 opacity-80" />
                <div className="min-w-0">
                  <h3 className="text-[14px] font-semibold text-ink">{item.title}</h3>
                  <p className="mt-2 text-[13px] leading-relaxed text-ink-muted">{item.body}</p>
                </div>
              </div>
            </article>
          ))}
        </div>

        <div className="cl-surface mt-4 border-[rgba(255,138,120,0.24)] bg-[rgba(255,96,74,0.05)] p-6">
          <h3 className="text-[14px] font-semibold text-[#ffb4a8]">
            Ownership verification is not implemented yet
          </h3>
          <p className="mt-2 max-w-3xl text-[13px] leading-relaxed text-ink-muted">
            This prototype does not verify that you own or are authorised to test the experience you
            connect it to. The architecture has a hook for universe ownership verification, but the
            check is not enabled. Using Clovyre in an experience you are not authorised to test is
            on you.
          </p>
        </div>
      </section>

      {/* Closing */}
      <section className="cl-shell mt-24 sm:mt-32">
        <div className="cl-surface-raised cl-glow-ring p-8 sm:p-12">
          <div className="max-w-xl">
            <h2 className="text-[26px] font-semibold leading-tight text-ink sm:text-[32px]">
              Create a session and copy one line.
            </h2>
            <p className="mt-4 text-[15px] leading-relaxed text-ink-muted">
              You will get a loadstring for your executor, a remote MCP endpoint for your agent, and
              a live dashboard showing exactly what each side is doing.
            </p>
            <div className="mt-8">
              <CreateSessionButton className="cl-btn-primary w-full sm:w-auto" />
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}

function FlowNode({
  label,
  detail,
  accent = false,
}: {
  label: string;
  detail: string;
  accent?: boolean;
}) {
  return (
    <div
      className={`flex-1 rounded-xl border px-4 py-3.5 ${
        accent ? 'border-line-strong bg-clover-600/10' : 'border-line bg-base-800/50'
      }`}
    >
      <div className="text-[13.5px] font-medium text-ink">{label}</div>
      <div className="mt-1 text-[11.5px] text-ink-faint">{detail}</div>
    </div>
  );
}

function FlowEdge({ label }: { label: string }) {
  return (
    <div className="flex w-24 shrink-0 flex-col items-center gap-1.5">
      <span className="font-mono text-[10.5px] text-clover-300">{label}</span>
      <span className="h-px w-full bg-gradient-to-r from-transparent via-clover-400/40 to-transparent" />
    </div>
  );
}
