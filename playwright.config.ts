import { defineConfig, devices } from '@playwright/test';

const PORT = Number(process.env.E2E_PORT ?? 3311);
const baseURL = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: './tests/e2e',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL,
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'] } },
    // Clovyre's primary target is an iPad, so the smoke suite runs there too.
    { name: 'ipad', use: { ...devices['iPad (gen 7)'], browserName: 'chromium' } },
  ],
  webServer: {
    command: 'node dist/server/index.js',
    url: `${baseURL}/api/health`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    env: {
      NODE_ENV: 'production',
      PORT: String(PORT),
      PUBLIC_BASE_URL: baseURL,
      SESSION_SECRET: 'e2e-session-secret-value-0123456789',
      TOKEN_HASH_SECRET: 'e2e-token-hash-secret-value-0123456789',
    },
  },
});
