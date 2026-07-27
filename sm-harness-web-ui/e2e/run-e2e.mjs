import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';

const base = process.env.BASE_URL || 'http://127.0.0.1:8080';
const artifacts = process.env.ARTIFACTS || './artifacts';
fs.mkdirSync(artifacts, { recursive: true });

async function waitForDisabled(page, selector, disabled) {
  await page.waitForFunction(
    ({ selector, disabled }) => document.querySelector(selector)?.disabled === disabled,
    { selector, disabled },
    { timeout: 15000 }
  );
}

async function newEvidencePage(browser, name) {
  const context = await browser.newContext({
    viewport: { width: 1280, height: 720 },
    recordVideo: { dir: artifacts, size: { width: 1280, height: 720 } }
  });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (error) => errors.push(`pageerror: ${error}`));
  page.on('console', (message) => {
    if (message.type() === 'error') errors.push(`console: ${message.text()}`);
  });
  await page.goto(base, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.locator('#home-root').waitFor({ state: 'visible', timeout: 30000 });
  return { context, page, errors, name };
}

async function completeEvidence(scenario, suffix) {
  const { context, page, errors, name } = scenario;
  await page.screenshot({ path: path.join(artifacts, `${name}-${suffix}.png`), fullPage: true });
  assert.deepEqual(errors, [], `${name}: unexpected browser errors`);
  await context.close(); // finalizes this scenario's native WebM
}

async function homeAndHealth(browser) {
  const scenario = await newEvidencePage(browser, 'home-health');
  const { page } = scenario;

  assert.equal(await page.getByText('e2e hello', { exact: true }).count(), 0);
  await assert.doesNotReject(page.getByRole('button', { name: 'New session' }).waitFor());
  await assert.doesNotReject(page.locator('#empty-sessions').waitFor({ state: 'visible' }));
  assert.equal(await page.locator('#home-status').innerText(), '');
  assert.equal(await page.title(), 'sm-harness');

  const newSession = page.getByRole('button', { name: 'New session' });
  await newSession.focus();
  assert.equal(await page.evaluate(() => document.activeElement?.id), 'new-session');
  await completeEvidence(scenario, 'empty-home');
}

async function newChatAndComposer(browser) {
  const scenario = await newEvidencePage(browser, 'new-chat-composer');
  const { page } = scenario;
  const newSession = page.getByRole('button', { name: 'New session' });

  // Keyboard activation proves the native button remains accessible.
  await newSession.focus();
  await page.keyboard.press('Enter');
  await page.locator('#chat-root').waitFor({ state: 'visible', timeout: 15000 });
  await page.locator('#canonical-id').getByText('Pending…').waitFor({ state: 'visible' });
  const prompt = page.locator('#prompt');
  await prompt.waitFor({ state: 'visible' });
  assert.equal(await page.evaluate(() => document.activeElement?.id), 'prompt');
  assert.equal(await page.locator('#send').isDisabled(), false);
  assert.equal(await page.locator('#stop').isDisabled(), true);

  // Whitespace stays in the draft and is visibly rejected without starting a turn.
  await prompt.fill('   ');
  await page.locator('#send').click();
  await page.locator('#chat-error').getByText(/prompt/i).waitFor({ state: 'visible' });
  assert.equal(await prompt.inputValue(), '   ');
  assert.equal(await page.locator('#send').isDisabled(), false);

  // Shift+Enter edits the textarea rather than submitting.
  await prompt.fill('line one');
  await prompt.press('Shift+Enter');
  assert.match(await prompt.inputValue(), /\n/);
  assert.equal(await page.locator('.msg-user').count(), 0);

  // A real Enter accepts exactly one turn; repeat activation is blocked while busy.
  await prompt.fill('hello e2e');
  await prompt.press('Enter');
  await waitForDisabled(page, '#send', true);
  await waitForDisabled(page, '#stop', false);
  await page.locator('#status-chip').getByText('Responding', { exact: true })
    .waitFor({ state: 'visible', timeout: 15000 });
  await page.locator('.msg-user').getByText('hello e2e', { exact: true }).waitFor({ state: 'visible' });
  await page.locator('.msg-assistant').getByText('e2e hello', { exact: true }).waitFor({ state: 'visible', timeout: 15000 });
  await page.locator('.msg-assistant').getByText('stream two: Unicode ✓\nsecond line', { exact: true })
    .waitFor({ state: 'visible', timeout: 15000 });
  await page.locator('.msg-assistant').filter({ hasText: 'unbroken-' })
    .waitFor({ state: 'visible', timeout: 15000 });
  const assistantText = await page.locator('.msg-assistant').allTextContents();
  const first = assistantText.findIndex((text) => text === 'e2e hello');
  const second = assistantText.findIndex((text) => text === 'stream two: Unicode ✓\nsecond line');
  const third = assistantText.findIndex((text) => text.startsWith('unbroken-'));
  assert.ok(first >= 0 && first < second && second < third, 'stream records retain order');
  assert.equal(
    await page.locator('#transcript').evaluate((node) => node.scrollWidth <= node.clientWidth),
    true,
    'long unbroken assistant output does not cause horizontal transcript blowout'
  );
  await page.locator('#status-chip').getByText('Ready', { exact: true }).waitFor({ state: 'visible' });
  await page.locator('#canonical-id').getByText('e2e-canon', { exact: true }).waitFor({ state: 'visible' });
  assert.equal(await page.locator('.msg-user').count(), 1);
  assert.equal(await prompt.inputValue(), '');
  assert.equal(await page.evaluate(() => document.activeElement?.id), 'prompt');

  // Canonical identity is persisted to the harness repository and exposed on Home.
  await page.locator('#back-home').click();
  await page.locator('#home-root').waitFor({ state: 'visible', timeout: 15000 });
  const row = page.locator('.session-row');
  await row.waitFor({ state: 'visible', timeout: 15000 });
  assert.equal(await row.count(), 1);
  await row.getByText(/New session — Ready — e2e-canon/).waitFor({ state: 'visible' });

  // Reopening the persisted row restores its displayed canonical identity/transcript.
  await row.click();
  await page.locator('#chat-root').waitFor({ state: 'visible', timeout: 15000 });
  await page.locator('#canonical-id').getByText('e2e-canon', { exact: true })
    .waitFor({ state: 'visible' });
  await page.locator('.msg-user').getByText('hello e2e', { exact: true })
    .waitFor({ state: 'visible' });
  await page.locator('.msg-assistant').getByText('e2e hello', { exact: true })
    .waitFor({ state: 'visible' });

  await completeEvidence(scenario, 'completed-turn');
}

const browser = await chromium.launch({ headless: true });
try {
  await homeAndHealth(browser);
  await newChatAndComposer(browser);
  console.log('e2e home/health + new-chat/composer completed');
} finally {
  await browser.close();
}
