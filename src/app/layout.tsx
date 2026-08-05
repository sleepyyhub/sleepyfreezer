import type { Metadata, Viewport } from 'next';
import Link from 'next/link';
import { Wordmark } from '@/components/brand';
import './globals.css';

export const metadata: Metadata = {
  title: {
    default: 'Clovyre MCP — Roblox client to MCP bridge',
    template: '%s · Clovyre MCP',
  },
  description:
    'Clovyre MCP bridges a live Roblox client to Claude and other MCP agents over a secure WebSocket ' +
    'and a remote MCP endpoint. No Studio, no local tooling, no desktop software.',
  applicationName: 'Clovyre MCP',
  robots: { index: true, follow: true },
  openGraph: {
    title: 'Clovyre MCP',
    description: 'A cloud bridge between a live Roblox client and remote MCP agents.',
    siteName: 'Clovyre MCP',
    type: 'website',
  },
};

export const viewport: Viewport = {
  themeColor: '#050a08',
  width: 'device-width',
  initialScale: 1,
  viewportFit: 'cover',
};

const footerLinks = [
  { href: '/docs', label: 'Documentation' },
  { href: '/privacy', label: 'Privacy' },
  { href: '/terms', label: 'Terms' },
  { href: 'https://github.com/sleepyyhub/sleepyfreezer', label: 'Repository', external: true },
];

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="flex min-h-dvh flex-col">
        <header className="sticky top-0 z-40 border-b border-line bg-base-900/80 backdrop-blur-md">
          <div className="cl-shell flex h-16 items-center justify-between gap-4">
            <Wordmark />
            <nav className="flex items-center gap-1.5 text-[13px]">
              <Link
                href="/docs"
                className="rounded-lg px-3 py-2 text-ink-muted transition-colors duration-200 ease-calm hover:text-ink"
              >
                Docs
              </Link>
              <Link href="/#start" className="cl-btn-primary !min-h-0 !px-3.5 !py-2 !text-[13px]">
                New session
              </Link>
            </nav>
          </div>
        </header>

        <main className="flex-1">{children}</main>

        <footer className="mt-20 border-t border-line py-10">
          <div className="cl-shell flex flex-col gap-6 sm:flex-row sm:items-center sm:justify-between">
            <div className="max-w-md">
              <Wordmark size="sm" href={null} />
              <p className="mt-3 text-[12.5px] leading-relaxed text-ink-faint">
                Clovyre reaches only what a live Roblox client already sees. Use it exclusively in
                experiences you own or are authorised to test.
              </p>
            </div>
            <nav className="flex flex-wrap gap-x-5 gap-y-2 text-[13px]">
              {footerLinks.map((link) =>
                link.external ? (
                  <a
                    key={link.href}
                    href={link.href}
                    target="_blank"
                    rel="noreferrer noopener"
                    className="text-ink-muted transition-colors duration-200 ease-calm hover:text-ink"
                  >
                    {link.label}
                  </a>
                ) : (
                  <Link
                    key={link.href}
                    href={link.href}
                    className="text-ink-muted transition-colors duration-200 ease-calm hover:text-ink"
                  >
                    {link.label}
                  </Link>
                ),
              )}
            </nav>
          </div>
        </footer>
      </body>
    </html>
  );
}
