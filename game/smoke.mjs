/**
 * Headless smoke test: boots the built game, plays for a while, and reports
 * HUD state, the written save, and any console errors. Not a substitute for
 * playtesting — it only proves the thing runs and progression persists.
 *
 *   npm run build && npx vite preview --port 4173 &
 *   node smoke.mjs http://localhost:4173/ ./shots
 */
import { chromium } from 'playwright';

const URL = process.argv[2] ?? 'http://localhost:4173/';
const OUT = process.argv[3] ?? '/tmp/shots';

const browser = await chromium.launch({
  // Pinned: the preinstalled browser does not match playwright's expected build.
  executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
  args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--no-sandbox'],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });

const errors = [];
page.on('console', (m) => {
  if (m.type() === 'error') errors.push(m.text());
});
page.on('pageerror', (e) => errors.push('PAGEERROR: ' + e.message));

await page.goto(URL, { waitUntil: 'networkidle' });
await page.waitForTimeout(1000);
await page.screenshot({ path: `${OUT}/01-title.png` });

await page.getByRole('button', { name: /Begin|Continue/ }).click();
await page.waitForTimeout(3000);
await page.screenshot({ path: `${OUT}/02-world.png` });

// Grind: run and swing. Enough kills to level up and accumulate loot.
for (let i = 0; i < 12; i++) {
  await page.keyboard.down('KeyW');
  await page.waitForTimeout(900);
  await page.keyboard.up('KeyW');
  for (let j = 0; j < 8; j++) {
    await page.mouse.click(640, 360);
    await page.waitForTimeout(220);
  }
  await page.keyboard.press('Space');
  await page.waitForTimeout(300);
  await page.keyboard.press('KeyQ');
  await page.waitForTimeout(300);
}
await page.screenshot({ path: `${OUT}/03-combat.png` });

await page.keyboard.press('KeyI');
await page.waitForTimeout(700);
await page.screenshot({ path: `${OUT}/04-inventory.png` });
await page.keyboard.press('Escape');
await page.keyboard.press('KeyC');
await page.waitForTimeout(700);
await page.screenshot({ path: `${OUT}/05-character.png` });
await page.keyboard.press('Escape');
await page.waitForTimeout(300);

const state = await page.evaluate(() => {
  const el = document.querySelector('#ui-root');
  return {
    uiText: el ? el.innerText : null,
    save: localStorage.getItem('verdant-reach:save:v1'),
  };
});

const save = state.save ? JSON.parse(state.save) : null;
console.log('--- HUD ---');
console.log(state.uiText);
console.log('--- SAVE ---');
console.log(
  save
    ? JSON.stringify(
        {
          level: save.level,
          xp: save.xp,
          statPoints: save.statPoints,
          kills: save.kills,
          zeni: save.currencies?.zeni,
          items: save.inventory?.length,
          flags: save.flags,
        },
        null,
        2,
      )
    : 'NO SAVE WRITTEN',
);
console.log('--- ERRORS (' + errors.length + ') ---');
for (const e of errors.slice(0, 15)) console.log(e);

await browser.close();
