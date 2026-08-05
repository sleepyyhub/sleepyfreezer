'use client';

import { useEffect, useState } from 'react';
import { StatusPill } from './ui';

interface HealthPayload {
  status: string;
  version: string;
  sessions: { active: number };
}

/** Live deployment indicator. Reports what it actually observed, never a guess. */
export function HealthPill() {
  const [state, setState] = useState<'checking' | 'ok' | 'down'>('checking');
  const [health, setHealth] = useState<HealthPayload | null>(null);

  useEffect(() => {
    let cancelled = false;

    const check = async () => {
      try {
        const response = await fetch('/api/health', { cache: 'no-store' });
        if (!response.ok) throw new Error('unhealthy');
        const payload = (await response.json()) as HealthPayload;
        if (cancelled) return;
        setHealth(payload);
        setState('ok');
      } catch {
        if (!cancelled) setState('down');
      }
    };

    void check();
    const timer = setInterval(check, 30_000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, []);

  if (state === 'checking') {
    return <StatusPill tone="idle">Checking service status</StatusPill>;
  }
  if (state === 'down') {
    return <StatusPill tone="down">Service unreachable</StatusPill>;
  }
  return (
    <StatusPill tone="live" pulse>
      {`Service operational · v${health?.version ?? '—'} · ${health?.sessions.active ?? 0} active`}
    </StatusPill>
  );
}
