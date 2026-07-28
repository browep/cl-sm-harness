import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const timeout = 30000;

export function videoArtifactName(scenarioName, timestamp = new Date()) {
  const utc = timestamp.toISOString().replace(/[-:.]/g, '').replace('Z', 'Z');
  return `${utc}-${scenarioName}.webm`;
}

function locator(page, step) {
  return page.locator(step.selector);
}

async function textLocator(page, step) {
  const target = locator(page, step);
  return step.text === undefined ? target : target.filter({ hasText: step.text });
}

async function executeStep(page, step) {
  const target = () => locator(page, step);
  switch (step.op) {
    case 'wait': return target().waitFor({ state: step.state ?? 'visible', timeout });
    case 'wait_text': return (await textLocator(page, step)).waitFor({ state: 'visible', timeout });
    case 'wait_pattern': return target().filter({ hasText: new RegExp(step.pattern) }).waitFor({ state: 'visible', timeout });
    case 'focus': return target().focus();
    case 'press': return step.selector ? target().press(step.key) : page.keyboard.press(step.key);
    case 'fill': return target().fill(step.value);
    case 'click': return target().click();
    case 'assert_title': return assert.equal(await page.title(), step.value);
    case 'assert_active_id': return assert.equal(await page.evaluate(() => document.activeElement?.id), step.value);
    case 'assert_disabled': return assert.equal(await target().isDisabled(), Boolean(step.value));
    case 'wait_disabled': return page.waitForFunction(({ selector, value }) => document.querySelector(selector)?.disabled === Boolean(value), { selector: step.selector, value: step.value }, { timeout });
    case 'assert_value': return assert.equal(await target().inputValue(), step.value);
    case 'assert_input_pattern': return assert.match(await target().inputValue(), new RegExp(step.pattern));
    case 'assert_count': return assert.equal(await target().count(), step.count);
    case 'assert_text_count': return assert.equal(await target().filter({ hasText: step.text }).count(), step.count);
    case 'assert_text': return assert.equal(await target().innerText(), step.value);
    case 'assert_text_order': {
      const text = await target().allTextContents();
      let after = -1;
      for (const value of step.values) {
        const index = text.findIndex((item, i) => i > after && item.startsWith(value));
        assert.ok(index > after, `expected ordered transcript value: ${value}`);
        after = index;
      }
      return;
    }
    case 'assert_attribute': return assert.equal(await target().getAttribute(step.name), step.value);
    case 'assert_overflow_fits': return assert.equal(await target().evaluate((node) => node.scrollWidth <= node.clientWidth), true);
    default: throw new Error(`unsupported E2E contract op: ${step.op}`);
  }
}

export async function loadContract(base) {
  const response = await fetch(new URL('/e2e-contract.json', base));
  assert.equal(response.ok, true, 'fixture app serves the Lisp E2E contract');
  return response.json();
}

export async function runScenario(browser, base, artifacts, scenario) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 }, recordVideo: { dir: artifacts, size: { width: 1280, height: 720 } } });
  const page = await context.newPage();
  const video = page.video();
  const errors = [];
  page.on('pageerror', (error) => errors.push(`pageerror: ${error}`));
  page.on('console', (message) => { if (message.type() === 'error') errors.push(`console: ${message.text()}`); });
  try {
    await page.goto(base, { waitUntil: 'domcontentloaded', timeout });
    for (const step of scenario.steps) await executeStep(page, step);
    await page.screenshot({ path: path.join(artifacts, `${scenario.name}-${scenario.evidence_suffix}.png`), fullPage: true });
    assert.deepEqual(errors, [], `${scenario.name}: unexpected browser errors`);
  } finally {
    await context.close();
    if (video) {
      const source = await video.path();
      fs.renameSync(source, path.join(artifacts, videoArtifactName(scenario.name)));
    }
  }
}

export function discoverScenarioNames(directory) {
  return fs.readdirSync(directory).filter((name) => name.endsWith('.mjs')).sort().map((name) => name.slice(0, -4));
}
