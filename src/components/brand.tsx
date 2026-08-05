import Link from 'next/link';

/**
 * Clovyre brand elements.
 *
 * The mark is a four-part geometric figure drawn as inline SVG — four rounded
 * quadrants set around a shared centre. It is an abstraction of a four-part form,
 * not an illustration of a clover, and there are no image assets anywhere.
 */

export function ClovyreMark({ size = 22, className = '' }: { size?: number; className?: string }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      aria-hidden="true"
      className={className}
    >
      <defs>
        <linearGradient id="cl-mark-a" x1="0" y1="0" x2="32" y2="32" gradientUnits="userSpaceOnUse">
          <stop stopColor="#6FD9A8" />
          <stop offset="1" stopColor="#178F60" />
        </linearGradient>
      </defs>
      {/* Four quadrants, each rotated 90° about the centre. */}
      <g fill="url(#cl-mark-a)">
        <path d="M15 3.6c0-1 .9-1.8 1.9-1.5 3.6 1 6.2 4.3 6.2 8.2 0 1.6-.4 3-1.2 4.3H16a1 1 0 0 1-1-1V3.6Z" />
        <path d="M28.4 15c1 0 1.8.9 1.5 1.9-1 3.6-4.3 6.2-8.2 6.2-1.6 0-3-.4-4.3-1.2V16a1 1 0 0 1 1-1h10Z" />
        <path d="M17 28.4c0 1-.9 1.8-1.9 1.5-3.6-1-6.2-4.3-6.2-8.2 0-1.6.4-3 1.2-4.3H16a1 1 0 0 1 1 1v10Z" />
        <path d="M3.6 17c-1 0-1.8-.9-1.5-1.9 1-3.6 4.3-6.2 8.2-6.2 1.6 0 3 .4 4.3 1.2V16a1 1 0 0 1-1 1H3.6Z" />
      </g>
      <circle cx="16" cy="16" r="1.6" fill="#050A08" opacity="0.55" />
    </svg>
  );
}

export function Wordmark({
  size = 'md',
  href = '/',
}: {
  size?: 'sm' | 'md' | 'lg';
  href?: string | null;
}) {
  const scale = size === 'lg' ? 'text-2xl' : size === 'sm' ? 'text-[15px]' : 'text-[17px]';
  const markSize = size === 'lg' ? 28 : size === 'sm' ? 18 : 22;

  const content = (
    <span className="inline-flex items-center gap-2.5">
      <ClovyreMark size={markSize} />
      <span className={`${scale} font-semibold tracking-[-0.02em] text-ink`}>
        Clovyre
        <span className="ml-1.5 align-middle text-[0.62em] font-medium uppercase tracking-[0.2em] text-ink-faint">
          MCP
        </span>
      </span>
    </span>
  );

  if (!href) return content;
  return (
    <Link href={href} className="transition-opacity duration-200 ease-calm hover:opacity-85">
      {content}
    </Link>
  );
}
