import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Terms',
  description: 'The terms under which Clovyre MCP is provided.',
};

export default function TermsPage() {
  return (
    <div className="cl-shell cl-rise max-w-3xl py-14 sm:py-20">
      <p className="cl-label">Policy</p>
      <h1 className="mt-3 text-[34px] font-semibold leading-tight tracking-[-0.03em] text-ink sm:text-[42px]">
        Terms of use
      </h1>
      <p className="mt-4 text-[13px] text-ink-faint">
        A plain statement of the terms this software is offered under. It is not legal advice and
        has not been reviewed by a lawyer.
      </p>

      <div className="mt-12 flex flex-col gap-10">
        <Block title="Authorised use only">
          <P>
            You may use Clovyre only with Roblox experiences you own, or that you have explicit
            permission to inspect and test. You are responsible for having that permission. Clovyre
            does not verify it — ownership verification is not implemented in this prototype.
          </P>
          <P>
            You are also responsible for complying with the Roblox Terms of Use and the rules of any
            experience you connect to. Nothing here grants you permission that Roblox or an
            experience owner has not given you.
          </P>
        </Block>

        <Block title="What the service does">
          <P>
            Clovyre relays inspection commands between a Roblox client you control and an MCP agent
            you connect. It reaches only what your client already receives. It does not bypass
            Roblox security boundaries, does not read server-only state, and does not grant access
            you did not already have.
          </P>
        </Block>

        <Block title="Privileged features">
          <P>
            Luau execution and mutation tools are disabled until you enable them yourself. Enabling
            them lets a connected agent run code or write state inside your client. You accept the
            consequences of doing so, including crashes, unexpected behaviour, and anything an agent
            does with that access.
          </P>
        </Block>

        <Block title="No warranty">
          <P>
            The service is provided as is, without warranty of any kind. It is a prototype. Sessions
            are temporary, state is not durable, and availability is not guaranteed. Do not rely on
            it for anything important.
          </P>
        </Block>

        <Block title="Limitation of liability">
          <P>
            To the maximum extent permitted by law, the authors are not liable for any damages
            arising from use of this software, including data loss, account action taken against
            you, or disruption to any experience you connect it to.
          </P>
        </Block>

        <Block title="Acceptable use">
          <P>
            Do not use Clovyre to attack, disrupt or gain unauthorised access to services or
            experiences, to harass anyone, or to violate anyone else&apos;s rights. Do not use it to
            attempt to circumvent anti-cheat systems in experiences you do not control.
          </P>
        </Block>
      </div>
    </div>
  );
}

function Block({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h2 className="text-[19px] font-semibold text-ink">{title}</h2>
      <div className="mt-3">{children}</div>
    </section>
  );
}

function P({ children }: { children: React.ReactNode }) {
  return (
    <p className="mt-3.5 text-[14.5px] leading-relaxed text-ink-muted first:mt-0">{children}</p>
  );
}
