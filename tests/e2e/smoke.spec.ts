import { expect, test } from '@playwright/test';

/**
 * Browser smoke suite against a production build.
 *
 * Runs on desktop Chrome and an iPad viewport, because the iPad is Clovyre's
 * primary target and layout regressions there are the ones that matter.
 */

test.describe('landing page', () => {
  test('renders the product, not a framework default', async ({ page }) => {
    await page.goto('/');

    await expect(page).toHaveTitle(/Clovyre MCP/);
    await expect(page.getByRole('heading', { level: 1 })).toContainText('Roblox client');
    await expect(page.getByText('Service operational', { exact: false })).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByRole('link', { name: 'Read the documentation' })).toBeVisible();
  });

  test('never scrolls horizontally', async ({ page }) => {
    await page.goto('/');
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(1);
  });

  test('logs no console errors', async ({ page }) => {
    const errors: string[] = [];
    page.on('console', (message) => {
      if (message.type() === 'error') errors.push(message.text());
    });
    page.on('pageerror', (error) => errors.push(error.message));

    await page.goto('/');
    await page.waitForLoadState('networkidle');
    expect(errors).toEqual([]);
  });
});

test.describe('session lifecycle', () => {
  test('creates a session, shows the loadstring, and reports a disconnected client', async ({
    page,
    context,
  }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Create session' }).first().click();

    await page.waitForURL(/\/session\/cs_[A-Z0-9]+/, { timeout: 20_000 });
    const sessionId = page.url().split('/session/')[1]!;
    expect(sessionId).toMatch(/^cs_[A-Z0-9]{20}$/);

    // Connection status must reflect reality: nothing is connected yet.
    await expect(page.getByText('Roblox not connected')).toBeVisible();
    await expect(page.getByText('No MCP client')).toBeVisible();
    await expect(page.getByText('Session active')).toBeVisible();

    // The generated loadstring is present and well formed.
    const loadstring = page.locator('pre', { hasText: 'ClovyreConfig' }).first();
    await expect(loadstring).toBeVisible();
    const text = (await loadstring.innerText()).trim();
    expect(text).toContain('getgenv().ClovyreConfig');
    expect(text).toContain(`SessionId = "${sessionId}"`);
    expect(text).toContain('RobloxToken = "crx_');
    expect(text).toContain('/client.lua');

    // The MCP endpoint is shown for this session.
    await expect(page.getByText(`/api/mcp/${sessionId}`).first()).toBeVisible();

    // Privileged tools must start off.
    const executeSwitch = page.getByRole('switch', { name: 'Luau execution' });
    await expect(executeSwitch).toHaveAttribute('aria-checked', 'false');

    // The copy control gives visible feedback.
    await context.grantPermissions(['clipboard-read', 'clipboard-write']).catch(() => undefined);
    const copyButton = page.getByRole('button', { name: 'Copy loadstring' }).first();
    await copyButton.click();
    await expect(page.getByRole('button', { name: /Copied|Press and hold to copy/ })).toBeVisible();

    // The dashboard fits without horizontal overflow.
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(1);
  });

  test('regenerates a script automatically after a reload', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Create session' }).first().click();
    await page.waitForURL(/\/session\/cs_/, { timeout: 20_000 });
    const sessionId = page.url().split('/session/')[1]!;

    const original = (await page.locator('pre', { hasText: 'ClovyreConfig' }).first().innerText()).trim();
    expect(original).toContain('RobloxToken = "crx_');

    // Wipe the tab's copy of the tokens, exactly as closing and reopening would.
    await page.evaluate((id) => sessionStorage.removeItem(`clovyre.secrets.${id}`), sessionId);
    await page.reload();

    // A fresh, working script must appear without the user doing anything.
    const regenerated = page.locator('pre', { hasText: 'ClovyreConfig' }).first();
    await expect(regenerated).toBeVisible({ timeout: 20_000 });
    const text = (await regenerated.innerText()).trim();

    expect(text).toContain(`SessionId = "${sessionId}"`);
    expect(text).toContain('RobloxToken = "crx_');
    // It must be a genuinely new credential, not the old one resurrected.
    expect(text).not.toEqual(original);

    await expect(page.getByRole('button', { name: 'Generate a new script' })).toBeVisible();
  });

  test('shows a connector URL that needs no header', async ({ page, request }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Create session' }).first().click();
    await page.waitForURL(/\/session\/cs_/, { timeout: 20_000 });
    const sessionId = page.url().split('/session/')[1]!;

    await expect(page.getByText('Add custom connector', { exact: false })).toBeVisible();

    const connectorUrl = (
      await page.locator('pre', { hasText: `/api/mcp/${sessionId}/cmc_` }).first().innerText()
    ).trim();
    expect(connectorUrl).toContain(`/api/mcp/${sessionId}/cmc_`);

    // The URL alone must authenticate, with no Authorization header at all.
    const response = await request.post(connectorUrl, {
      headers: { 'content-type': 'application/json' },
      data: { jsonrpc: '2.0', id: 1, method: 'tools/list' },
    });
    expect(response.ok()).toBe(true);
    const body = await response.json();
    expect(body.result.tools.length).toBeGreaterThan(20);

    // A wrong token in the same position must still be refused.
    const bad = await request.post(`/api/mcp/${sessionId}/cmc_wrongtoken`, {
      headers: { 'content-type': 'application/json' },
      data: { jsonrpc: '2.0', id: 1, method: 'tools/list' },
    });
    expect(bad.status()).toBe(401);
  });

  test('explorer and scripts explain themselves with no client attached', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Create session' }).first().click();
    await page.waitForURL(/\/session\/cs_/, { timeout: 20_000 });
    const sessionId = page.url().split('/session/')[1]!;

    await page.goto(`/session/${sessionId}/explorer`);
    await expect(page.getByText('No Roblox client is connected.')).toBeVisible();

    await page.goto(`/session/${sessionId}/scripts`);
    await expect(page.getByText('No Roblox client is connected.')).toBeVisible();

    await page.goto(`/session/${sessionId}/activity`);
    await expect(page.getByText('No commands yet.')).toBeVisible();
  });

  test('a session cannot be opened without the owner credential', async ({ browser, page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Create session' }).first().click();
    await page.waitForURL(/\/session\/cs_/, { timeout: 20_000 });
    const sessionId = page.url().split('/session/')[1]!;

    // A second, cookie-less browser context must be refused.
    const stranger = await browser.newContext();
    const strangerPage = await stranger.newPage();
    await strangerPage.goto(`/session/${sessionId}`);
    await expect(strangerPage.getByText('This session is not open here')).toBeVisible();
    await stranger.close();
  });
});

test.describe('public endpoints', () => {
  test('health reports service status without leaking configuration', async ({ request }) => {
    const response = await request.get('/api/health');
    expect(response.ok()).toBe(true);

    const body = await response.json();
    expect(body.status).toBe('ok');
    expect(body.service).toBe('clovyre-mcp');
    expect(body.protocolVersion).toBe(1);
    expect(body.features.executeLuau).toBeDefined();
    expect(body.features.ownershipVerification).toBe(false);

    const serialised = JSON.stringify(body);
    expect(serialised).not.toContain('SECRET');
    expect(serialised).not.toMatch(/crx_|cmc_|cow_|rnd_/);
  });

  test('client.lua serves the bridge as plain text with no credentials', async ({ request }) => {
    const response = await request.get('/client.lua');
    expect(response.ok()).toBe(true);
    expect(response.headers()['content-type']).toContain('text/plain');

    const source = await response.text();
    expect(source).toContain('ClovyreConfig');
    expect(source).toContain('getgenv().ClovyreDisconnect');
    expect(source).toContain('protocolVersion');
    // The public script must never embed a session credential.
    expect(source).not.toMatch(/crx_[A-Za-z0-9]{20,}/);
  });

  test('the MCP endpoint rejects an unauthenticated call', async ({ request }) => {
    const response = await request.post('/api/mcp/cs_AAAAAAAAAAAAAAAAAAAA', {
      data: { jsonrpc: '2.0', id: 1, method: 'tools/list' },
    });
    expect(response.status()).toBe(404);
    const body = await response.json();
    expect(body.error.message).toContain('Unknown Clovyre session');
  });

  test('the MCP endpoint answers initialize and tools/list with a valid token', async ({
    page,
    request,
  }) => {
    // Create a session through the UI so the token comes from the real flow.
    await page.goto('/');
    await page.getByRole('button', { name: 'Create session' }).first().click();
    await page.waitForURL(/\/session\/cs_/, { timeout: 20_000 });
    const sessionId = page.url().split('/session/')[1]!;

    const token = await page.evaluate((id) => {
      const raw = sessionStorage.getItem(`clovyre.secrets.${id}`);
      return raw ? (JSON.parse(raw) as { mcpToken: string }).mcpToken : null;
    }, sessionId);
    expect(token).toBeTruthy();

    const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };

    const initialize = await request.post(`/api/mcp/${sessionId}`, {
      headers,
      data: {
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: { protocolVersion: '2025-06-18', clientInfo: { name: 'playwright', version: '1' } },
      },
    });
    expect(initialize.ok()).toBe(true);
    const initBody = await initialize.json();
    expect(initBody.result.serverInfo.name).toBe('clovyre-mcp');

    const list = await request.post(`/api/mcp/${sessionId}`, {
      headers,
      data: { jsonrpc: '2.0', id: 2, method: 'tools/list' },
    });
    const listBody = await list.json();
    const names = (listBody.result.tools as Array<{ name: string }>).map((tool) => tool.name);
    expect(names).toContain('clovyre_session_info');
    expect(names).toContain('clovyre_get_children');
    // Privileged tools stay hidden until the owner grants them in the browser.
    expect(names).not.toContain('clovyre_execute_luau');

    const call = await request.post(`/api/mcp/${sessionId}`, {
      headers,
      data: {
        jsonrpc: '2.0',
        id: 3,
        method: 'tools/call',
        params: { name: 'clovyre_execute_luau', arguments: { code: 'return 1' } },
      },
    });
    const callBody = await call.json();
    expect(callBody.result.isError).toBe(true);
    expect(callBody.result.structuredContent.code).toBe('PRIVILEGE_REQUIRED');
  });

  test('a wrong bearer token is rejected', async ({ page, request }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Create session' }).first().click();
    await page.waitForURL(/\/session\/cs_/, { timeout: 20_000 });
    const sessionId = page.url().split('/session/')[1]!;

    const response = await request.post(`/api/mcp/${sessionId}`, {
      headers: { authorization: 'Bearer cmc_definitely_not_the_right_token' },
      data: { jsonrpc: '2.0', id: 1, method: 'tools/list' },
    });
    expect(response.status()).toBe(401);
  });

  test('security headers are present', async ({ request }) => {
    const response = await request.get('/');
    const headers = response.headers();
    expect(headers['content-security-policy']).toContain("default-src 'self'");
    expect(headers['x-content-type-options']).toBe('nosniff');
    expect(headers['x-frame-options']).toBe('DENY');
    expect(headers['referrer-policy']).toBe('strict-origin-when-cross-origin');
  });

  test('documentation, privacy and terms all render', async ({ page }) => {
    for (const [path, heading] of [
      ['/docs', 'How Clovyre works, precisely.'],
      ['/privacy', 'Privacy'],
      ['/terms', 'Terms of use'],
    ] as const) {
      await page.goto(path);
      await expect(page.getByRole('heading', { level: 1 })).toContainText(heading);
    }
  });
});
