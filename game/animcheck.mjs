/**
 * Animation/model inspection harness. Boots the game, forces the camera close
 * and steady, then samples frames across combat so the rigs and clips can be
 * eyeballed. Screenshot review is the only way to verify animation — no
 * assertion tells you whether a walk cycle looks like walking.
 */
import { chromium } from 'playwright';

const OUT = process.argv[2] ?? '/tmp/shots';

const browser = await chromium.launch({
  executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome',
  args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader', '--no-sandbox'],
});
const page = await browser.newPage({ viewport: { width: 900, height: 760 } });

const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
page.on('console', (m) => {
  if (m.type() === 'error') errors.push(m.text());
});

await page.goto('http://localhost:4173/', { waitUntil: 'networkidle' });
await page.waitForTimeout(800);
await page.getByRole('button', { name: /Begin|Continue/ }).click();
await page.waitForTimeout(2500);

// Pull the camera in close: model detail is the thing under review here.
await page.mouse.wheel(0, -1100);
await page.waitForTimeout(600);

const shot = (n) => page.screenshot({ path: `${OUT}/anim-${n}.png` });

// Idle: the character should be visibly breathing and shifting weight.
await shot('01-idle');

// Walk, then run — hold W and sample at two speeds.
await page.keyboard.down('KeyW');
await page.waitForTimeout(700);
await shot('02-locomotion-a');
await page.waitForTimeout(400);
await shot('03-locomotion-b');
await page.keyboard.up('KeyW');
await page.waitForTimeout(400);

// Attack chain: sample each link mid-swing.
await page.mouse.click(450, 380);
await page.waitForTimeout(130);
await shot('04-light1');
await page.waitForTimeout(220);
await page.mouse.click(450, 380);
await page.waitForTimeout(150);
await shot('05-light2');
await page.waitForTimeout(230);
await page.mouse.click(450, 380);
await page.waitForTimeout(220);
await shot('06-light3-kick');
await page.waitForTimeout(700);

// Heavy: sample at the top of the wind-up and again on the slam.
await page.keyboard.press('KeyF');
await page.waitForTimeout(300);
await shot('07-heavy-windup');
await page.waitForTimeout(220);
await shot('08-heavy-impact');
await page.waitForTimeout(700);

// Special.
await page.keyboard.press('KeyQ');
await page.waitForTimeout(280);
await shot('09-special-charge');
await page.waitForTimeout(230);
await shot('10-special-release');
await page.waitForTimeout(700);

// Dodge roll, mid-tumble.
await page.keyboard.press('Space');
await page.waitForTimeout(200);
await shot('11-dodge');
await page.waitForTimeout(600);

// Walk into the pack south to catch enemies animating and attacking.
for (let i = 0; i < 6; i++) {
  await page.keyboard.down('KeyW');
  await page.waitForTimeout(800);
  await page.keyboard.up('KeyW');
  await page.waitForTimeout(250);
  const txt = await page.evaluate(() => document.querySelector('#ui-root').innerText);
  if (/Zhun/i.test(txt)) break;
}
await shot('12-enemies');
await page.waitForTimeout(900);
await shot('13-enemies-b');
await page.waitForTimeout(900);
await shot('14-boss');

const info = await page.evaluate(() => ({
  ui: document.querySelector('#ui-root').innerText,
}));
console.log('--- HUD ---');
console.log(info.ui);
console.log('--- ERRORS (' + errors.length + ') ---');
for (const e of errors.slice(0, 10)) console.log(e);

await browser.close();
