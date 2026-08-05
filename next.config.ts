import type { NextConfig } from 'next';

/**
 * Clovyre runs behind a custom Node server (server/index.ts) so that the
 * Roblox WebSocket gateway can share a process with the Next.js app.
 */
/**
 * Content Security Policy.
 *
 * Clovyre loads no external images, fonts, scripts or styles, so every fetch
 * directive can be locked to 'self'. `connect-src` also allows wss: because the
 * dashboard reports on a same-origin WebSocket endpoint. Inline styles are
 * permitted for Tailwind's injected styles and React style attributes; inline
 * script is permitted for the hydration payload Next.js inlines by design.
 */
const contentSecurityPolicy = [
  "default-src 'self'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
  "object-src 'none'",
  "img-src 'self' data:",
  "font-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  `script-src 'self' 'unsafe-inline'${process.env.NODE_ENV === 'production' ? '' : " 'unsafe-eval'"}`,
  "connect-src 'self' ws: wss:",
  'upgrade-insecure-requests',
].join('; ');

const securityHeaders = [
  { key: 'Content-Security-Policy', value: contentSecurityPolicy },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
  { key: 'Cross-Origin-Opener-Policy', value: 'same-origin' },
  { key: 'X-DNS-Prefetch-Control', value: 'off' },
  { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains' },
];

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  productionBrowserSourceMaps: false,
  // No remote or optimized images are used anywhere in Clovyre.
  images: { unoptimized: true },
  outputFileTracingRoot: __dirname,
  async headers() {
    return [{ source: '/:path*', headers: securityHeaders }];
  },
};

export default nextConfig;
