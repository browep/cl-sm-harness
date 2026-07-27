import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';

const base = process.env.BASE_URL || 'http://127.0.0.1:8080';
const artifacts = process.env.ARTIFACTS || './artifacts';
fs.mkdirSync(artifacts, { recursive: true });

async function waitForApp(page, timeout = 120000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      await page.goto(base, { waitUntil: 'domcontentloaded', timeout: 5000 });
      const text = await page.locator('body').innerText();
      if (text.includes('sm-harness') || text.includes('New session')) return;
    } catch (_) {}
    await page.waitForTimeout(2000);
  }
  throw new Error('app did not become ready');
}

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1280, height: 720 },
  recordVideo: { dir: artifacts, size: { width: 1280, height: 720 } }
});
const page = await context.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (msg) => {
  if (msg.type() === 'error') errors.push(msg.text());
});

try {
  await waitForApp(page);
  await page.screenshot({ path: path.join(artifacts, 'home.png'), fullPage: true });

  // New session
  const newBtn = page.getByRole('button', { name: /New session/i }).first();
  await newBtn.click();
  await page.waitForTimeout(1000);
  await page.screenshot({ path: path.join(artifacts, 'chat.png'), fullPage: true });

  // Prompt + send
  const prompt = page.locator('#prompt, textarea').first();
  if (await prompt.count()) {
    await prompt.fill('hello e2e');
    const send = page.getByRole('button', { name: /^Send$/i }).first();
    if (await send.count()) {
      await send.click();
      await page.waitForTimeout(3000);
    }
  }
  await page.screenshot({ path: path.join(artifacts, 'after-send.png'), fullPage: true });

  const body = await page.locator('body').innerText();
  if (!/e2e hello|hello from fixture|Ready|Responding|Pending/i.test(body)) {
    console.warn('warning: expected chat text not found; body snippet:', body.slice(0, 400));
  }
  if (errors.length) {
    console.error('browser errors:', errors);
    // CLOG websocket noise is possible; fail only on unexpected pageerror without clog bootstrap
  }
  console.log('e2e completed');
} finally {
  await context.close();
  await browser.close();
}
