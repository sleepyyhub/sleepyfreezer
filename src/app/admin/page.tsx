import { cookies, headers } from 'next/headers';
import { notFound } from 'next/navigation';
import type { Metadata } from 'next';
import { verifyAdminCookie, verifyAdminToken } from '@/lib/admin/auth';
import { getConfig } from '@/lib/config';
import { getRateLimiter } from '@/lib/security/rate-limit';
import { AdminConsole } from '@/components/admin/console';

/**
 * Operator console.
 *
 * Unauthenticated requests get Next.js's ordinary 404 — the same page a typo
 * produces. There is no login form, no branded "access denied", and no link to
 * this route anywhere in the application, so the page's existence is not
 * discoverable by browsing.
 *
 * Bootstrap by visiting /admin?k=<ADMIN_TOKEN> once; that sets an httpOnly,
 * SameSite=Strict cookie and subsequent visits need no query string. A token in
 * a URL is visible to access logs, so treat that first visit as the one moment
 * the secret is exposed and rely on the cookie afterwards.
 */

export const dynamic = 'force-dynamic';

export const metadata: Metadata = {
  title: 'Not Found',
  robots: { index: false, follow: false, nocache: true },
};

export default async function AdminPage({
  searchParams,
}: {
  searchParams: Promise<{ k?: string }>;
}) {
  const config = getConfig();
  if (!config.adminEnabled) notFound();

  const cookieStore = await cookies();
  if (verifyAdminCookie(cookieStore.get('clovyre_operator')?.value)) {
    return <AdminConsole />;
  }

  const { k } = await searchParams;
  if (!k) notFound();

  // Rate limit guesses by address, exactly as the API route does.
  const headerStore = await headers();
  const address =
    headerStore.get('x-forwarded-for')?.split(',')[0]?.trim() ??
    headerStore.get('x-real-ip') ??
    'unknown';

  if (!getRateLimiter().check('admin_login', address).allowed) notFound();
  if (!verifyAdminToken(k)) notFound();

  // The client component exchanges the secret for the cookie on first load.
  return <AdminConsole bootstrapToken={k} />;
}
