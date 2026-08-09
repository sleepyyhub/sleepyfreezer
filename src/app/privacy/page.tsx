import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Privacy',
  description: 'What Clovyre MCP handles, for how long, and what it never stores.',
};

export default function PrivacyPage() {
  return (
    <div className="cl-shell cl-rise max-w-3xl py-14 sm:py-20">
      <p className="cl-label">Policy</p>
      <h1 className="mt-3 text-[34px] font-semibold leading-tight tracking-[-0.03em] text-ink sm:text-[42px]">
        Privacy
      </h1>
      <p className="mt-4 text-[13px] text-ink-faint">
        This is a plain description of how the software behaves, written by the people who built it.
        It is not legal advice and it is not a substitute for a policy reviewed by a lawyer.
      </p>

      <div className="mt-12 flex flex-col gap-10">
        <Block title="What a session holds">
          <P>
            Creating a session allocates a record containing: a public session id, HMAC digests of
            four credentials, timestamps, the capability list your executor reported, the place and
            job identifiers your client sent, your local player name and user id, an abbreviated
            command history, and a redacted audit trail.
          </P>
          <P>
            Instance data, script text and tool results pass through the service in transit. They
            are relayed to the requesting agent and are not written to disk. Only short, redacted
            previews of arguments and results are retained in the session activity log.
          </P>
        </Block>

        <Block title="What is never stored">
          <P>
            Plaintext credentials are never stored. Tokens are generated, shown to you once, and
            retained only as keyed digests. IP addresses are never stored in the clear — they are
            salted and hashed, and the digest is used solely for rate limiting and audit
            correlation.
          </P>
          <P>
            No analytics, no advertising identifiers, no third-party trackers, no external image or
            font requests. The service sets two cookies, both scoped to a single session: an
            httpOnly owner credential and a readable CSRF token. Both expire with the session.
          </P>
        </Block>

        <Block title="How long anything lasts">
          <P>
            A session lasts until you terminate it, and it is stored in a database so that it
            survives a restart or a redeploy — that is what lets you configure an agent once.
            Terminating a session deletes its stored row. The transient parts (live connection,
            command history, activity log) are held only in process memory and are gone the moment
            the service restarts.
          </P>
        </Block>

        <Block title="Operational logs">
          <P>
            The service writes minimal operational logs — startup, shutdown and unhandled errors.
            Credential values, authorization headers and session tokens are redacted before anything
            is written. Your hosting provider will separately record request metadata according to
            its own policies.
          </P>
        </Block>

        <Block title="What the service operator can see">
          <P>
            Whoever runs this deployment can view a console listing currently connected sessions. It
            shows the Roblox account each session reported — username, display name and user id —
            the executor name, the place, and which AI agent is connected, along with connection
            times. This is connection metadata the service already receives in order to function.
          </P>
          <P>
            That console deliberately cannot show anything else. It has no access to credentials, no
            access to the contents of tool calls, and no way to see what any agent read from your
            game. It also provides no ability to act on your session. If you would rather an
            operator not see that you are connected, do not connect.
          </P>
        </Block>

        <Block title="Your responsibility">
          <P>
            Clovyre can read what your Roblox client can read. If you connect it to an experience,
            the data that experience replicates to you becomes visible to whichever agent you
            connected. Only use Clovyre in experiences you own or are explicitly authorised to test,
            and only connect agents you trust.
          </P>
        </Block>

        <Block title="Changes">
          <P>
            This document describes the current behaviour of the software. If the behaviour changes,
            this page changes with it in the same commit.
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
