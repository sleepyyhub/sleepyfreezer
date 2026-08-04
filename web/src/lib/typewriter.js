import { useEffect, useRef, useState } from 'react';

/**
 * Reveal text as if it were being typed.
 *
 * Driven by elapsed time rather than a fixed per-character interval, so the
 * pace stays even when the browser drops frames, and a long message never
 * takes proportionally forever — the duration is capped and the rate scales up
 * to meet it.
 */

const CHARS_PER_SECOND = 55;
const MAX_DURATION_MS = 4500;

const prefersReducedMotion = () =>
  typeof window !== 'undefined'
  && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

export function useTypewriter(text, { enabled = true } = {}) {
  const full = text ?? '';
  const skip = !enabled || prefersReducedMotion();

  const [shown, setShown] = useState(skip ? full : '');
  const frame = useRef(null);

  useEffect(() => {
    if (skip) {
      setShown(full);
      return undefined;
    }

    // Long messages speed up rather than dragging on.
    const natural = (full.length / CHARS_PER_SECOND) * 1000;
    const duration = Math.min(natural, MAX_DURATION_MS);
    const started = performance.now();

    const step = (now) => {
      const progress = duration === 0 ? 1 : Math.min(1, (now - started) / duration);
      const count = Math.ceil(progress * full.length);
      setShown(full.slice(0, count));
      if (progress < 1) frame.current = requestAnimationFrame(step);
    };

    frame.current = requestAnimationFrame(step);
    return () => {
      if (frame.current) cancelAnimationFrame(frame.current);
    };
  }, [full, skip]);

  return { shown, done: shown.length >= full.length };
}

export default useTypewriter;
