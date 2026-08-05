'use client';

import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';

/**
 * Shared interface primitives. Everything here is touch-first: no hover-only
 * affordances, 44px minimum targets, and visible feedback on every action.
 */

export function StatusDot({
  tone,
  pulse = false,
}: {
  tone: 'live' | 'idle' | 'warn' | 'down';
  pulse?: boolean;
}) {
  const color =
    tone === 'live'
      ? 'bg-clover-300'
      : tone === 'warn'
        ? 'bg-amber-300'
        : tone === 'down'
          ? 'bg-[#ff8a78]'
          : 'bg-ink-faint';
  return (
    <span className="relative inline-flex h-2 w-2 shrink-0">
      {pulse && tone === 'live' ? (
        <span
          className={`absolute inline-flex h-full w-full rounded-full ${color} animate-pulse-soft`}
        />
      ) : null}
      <span className={`relative inline-flex h-2 w-2 rounded-full ${color}`} />
    </span>
  );
}

export function StatusPill({
  tone,
  children,
  pulse = false,
}: {
  tone: 'live' | 'idle' | 'warn' | 'down';
  children: ReactNode;
  pulse?: boolean;
}) {
  return (
    <span className="cl-pill">
      <StatusDot tone={tone} pulse={pulse} />
      {children}
    </span>
  );
}

/** Copy control with explicit, timed visual feedback and a graceful fallback. */
export function CopyButton({
  value,
  label = 'Copy',
  className = 'cl-btn-ghost',
}: {
  value: string;
  label?: string;
  className?: string;
}) {
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle');
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    [],
  );

  const copy = useCallback(async () => {
    const reset = () => {
      if (timer.current) clearTimeout(timer.current);
      timer.current = setTimeout(() => setState('idle'), 2000);
    };
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(value);
      } else {
        // Safari denies the async API outside secure contexts; fall back cleanly.
        const area = document.createElement('textarea');
        area.value = value;
        area.setAttribute('readonly', '');
        area.style.position = 'fixed';
        area.style.opacity = '0';
        document.body.appendChild(area);
        area.select();
        const ok = document.execCommand('copy');
        document.body.removeChild(area);
        if (!ok) throw new Error('copy rejected');
      }
      setState('copied');
    } catch {
      setState('failed');
    }
    reset();
  }, [value]);

  return (
    <button type="button" onClick={copy} className={className} aria-live="polite">
      {state === 'copied' ? 'Copied' : state === 'failed' ? 'Press and hold to copy' : label}
    </button>
  );
}

export function CodeBlock({
  code,
  copyLabel = 'Copy',
  caption,
}: {
  code: string;
  copyLabel?: string;
  caption?: string;
}) {
  return (
    <div className="cl-surface overflow-hidden">
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-line px-4 py-2.5">
        <span className="cl-label">{caption ?? 'Snippet'}</span>
        <CopyButton
          value={code}
          label={copyLabel}
          className="cl-btn-ghost !min-h-0 !px-3 !py-1.5 !text-xs"
        />
      </div>
      <pre className="cl-scroll max-h-80 px-4 py-3.5 text-[12.5px] leading-relaxed text-ink-muted">
        <code>{code}</code>
      </pre>
    </div>
  );
}

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <div className="cl-label mb-1">{label}</div>
      <div className="truncate text-sm text-ink">{children}</div>
    </div>
  );
}

export function Panel({
  title,
  description,
  actions,
  children,
  tone = 'default',
}: {
  title: string;
  description?: string;
  actions?: ReactNode;
  children: ReactNode;
  tone?: 'default' | 'alert';
}) {
  return (
    <section
      className={`cl-surface p-5 sm:p-6 ${
        tone === 'alert' ? 'border-[rgba(255,138,120,0.28)] bg-[rgba(255,96,74,0.05)]' : ''
      }`}
    >
      <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-[15px] font-semibold text-ink">{title}</h2>
          {description ? <p className="mt-1 text-[13px] text-ink-muted">{description}</p> : null}
        </div>
        {actions ? <div className="flex flex-wrap items-center gap-2">{actions}</div> : null}
      </div>
      {children}
    </section>
  );
}

export function EmptyState({ title, hint }: { title: string; hint?: string }) {
  return (
    <div className="rounded-xl border border-dashed border-line px-4 py-8 text-center">
      <p className="text-sm text-ink-muted">{title}</p>
      {hint ? <p className="mt-1.5 text-[12.5px] text-ink-faint">{hint}</p> : null}
    </div>
  );
}

export function ErrorNote({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-[rgba(255,138,120,0.3)] bg-[rgba(255,96,74,0.07)] px-4 py-3">
      <p className="text-[13px] text-[#ffb4a8]">{message}</p>
      {onRetry ? (
        <button
          type="button"
          onClick={onRetry}
          className="cl-btn-ghost !min-h-0 !px-3 !py-1.5 !text-xs"
        >
          Try again
        </button>
      ) : null}
    </div>
  );
}

/** Destructive-action guard: two deliberate taps, never one. */
export function ConfirmButton({
  onConfirm,
  label,
  confirmLabel,
  className = 'cl-btn-danger',
  disabled = false,
}: {
  onConfirm: () => void | Promise<void>;
  label: string;
  confirmLabel: string;
  className?: string;
  disabled?: boolean;
}) {
  const [armed, setArmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    [],
  );

  return (
    <button
      type="button"
      className={className}
      disabled={disabled || busy}
      onClick={async () => {
        if (!armed) {
          setArmed(true);
          if (timer.current) clearTimeout(timer.current);
          timer.current = setTimeout(() => setArmed(false), 5000);
          return;
        }
        setArmed(false);
        setBusy(true);
        try {
          await onConfirm();
        } finally {
          setBusy(false);
        }
      }}
    >
      {busy ? 'Working…' : armed ? confirmLabel : label}
    </button>
  );
}

export function Toggle({
  checked,
  onChange,
  label,
  disabled = false,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  label: string;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={`relative inline-flex h-7 w-12 shrink-0 items-center rounded-full border transition-colors duration-200 ease-calm ${
        checked ? 'border-clover-400 bg-clover-600/50' : 'border-line bg-base-700'
      } ${disabled ? 'cursor-not-allowed opacity-45' : ''}`}
    >
      <span
        className={`inline-block h-5 w-5 rounded-full transition-transform duration-200 ease-calm ${
          checked ? 'translate-x-6 bg-clover-200' : 'translate-x-1 bg-ink-faint'
        }`}
      />
    </button>
  );
}

export function relativeTime(iso: string | null): string {
  if (!iso) return '—';
  const delta = Date.now() - new Date(iso).getTime();
  const seconds = Math.round(delta / 1000);
  if (seconds < 5) return 'just now';
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  return `${hours}h ago`;
}

export function formatDuration(seconds: number): string {
  if (seconds <= 0) return '0s';
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  if (minutes === 0) return `${remainder}s`;
  return `${minutes}m ${String(remainder).padStart(2, '0')}s`;
}
