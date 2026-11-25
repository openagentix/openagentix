// Captures the console screenshots used by the README and the docs site, from the console in demo mode.
//
//   services/console/build-web.sh
//   (cd services/console && CONSOLE_DEV_FAKE=1 CONSOLE_DEV_FAKE_SETTLE=0 CONSOLE_ADDR=127.0.0.1:18099 go run ./cmd/console) &
//   cd console && CONSOLE_URL=http://127.0.0.1:18099 node scripts/capture-screenshots.mjs
//
// Output: docs/assets/console/<page>-<light|dark>.webp, 1440 px wide at 2x scale. The PNG capture is converted with
// ImageMagick (`magick`, quality 80), which keeps each file under 300 KB. Demo mode holds fake data only,
// and the token typed is the public demo token.
import { chromium } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const base = process.env.CONSOLE_URL || 'http://127.0.0.1:18099';
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../docs/assets/console');
fs.mkdirSync(out, { recursive: true });

const pages = [
    ['overview', '/'],
    ['agents', '/agents'],
    ['builder', '/agents/new'],
    ['costs', '/costs'],
    ['traces', '/traces'],
    ['governance', '/governance'],
];
const themes = (process.env.THEMES || 'light,dark').split(',');

const browser = await chromium.launch();
for (const theme of themes) {
    const ctx = await browser.newContext({
        viewport: { width: 1440, height: 900 },
        deviceScaleFactor: 2,
        colorScheme: theme,
        reducedMotion: 'reduce',
    });
    const page = await ctx.newPage();
    await page.addInitScript((t) => localStorage.setItem('oa-theme', t), theme);
    await page.goto(base + '/');
    await page.getByLabel('Console token').fill('demo-token');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.locator('nav[aria-label="Main"]').waitFor();
    for (const [name, href] of pages) {
        if (href === '/agents/new') {
            await page
                .getByRole('button', { name: /New agent/ })
                .first()
                .click();
        } else if (href !== '/') {
            await page.locator(`nav[aria-label="Main"] a[href$="${href}"], main a[href$="${href}"]`).first().click();
        } else {
            await page
                .locator('nav[aria-label="Main"] a[href$="/"], nav[aria-label="Main"] a[href=""]')
                .first()
                .click()
                .catch(() => {});
        }
        await page.waitForLoadState('networkidle');
        await page.waitForTimeout(600);
        const png = path.join(out, `${name}-${theme}.png`);
        await page.screenshot({ path: png });
        execFileSync('magick', [png, '-quality', '80', '-define', 'webp:method=6', png.replace(/\.png$/, '.webp')]);
        fs.rmSync(png);
        console.log('captured', name, theme);
    }
    await ctx.close();
}
await browser.close();
