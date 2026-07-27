import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './ui/App';

const root = document.getElementById('ui-root');
if (!root) throw new Error('#ui-root missing from index.html');

createRoot(root).render(
  // StrictMode double-invokes effects in dev; the Game effect is guarded by a
  // ref and a full dispose(), so the second mount tears down cleanly.
  <StrictMode>
    <App />
  </StrictMode>,
);
