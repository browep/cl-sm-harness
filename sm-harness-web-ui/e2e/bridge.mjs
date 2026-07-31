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

async function executeStep(page, base, step) {
  const target = () => locator(page, step);
  switch (step.op) {
    case 'wait': return target().waitFor({ state: step.state ?? 'visible', timeout });
    case 'wait_text': return (await textLocator(page, step)).waitFor({ state: 'visible', timeout });
    case 'wait_pattern': return target().filter({ hasText: new RegExp(step.pattern) }).waitFor({ state: 'visible', timeout });
    case 'focus': return target().focus();
    case 'press': return step.selector ? target().press(step.key) : page.keyboard.press(step.key);
    case 'fill': return target().fill(step.value);
    // Generic Playwright operation: choose an <option> by its value
    // attribute on a <select> -- 'fill' does not work on <select>
    // elements, Playwright requires selectOption instead.
    case 'select_option': return target().selectOption(step.value);
    case 'click': return target().click();
    case 'goto': return page.goto(new URL(step.path, base).toString(), { waitUntil: 'domcontentloaded', timeout });
    case 'reload': return page.reload({ waitUntil: 'domcontentloaded', timeout });
    // #125: the browser Back button, exercised for real via Playwright's
    // own history navigation (not a click on any in-app control) --
    // this is what actually caught the tab-closing bug, which only shows
    // up on genuine browser back/forward, never on an app-level link.
    case 'go_back': return page.goBack({ waitUntil: 'domcontentloaded', timeout });
    case 'sleep': return new Promise((resolve) => setTimeout(resolve, step.milliseconds));
    // Generic Playwright operation, not app-specific: open a second tab in
    // this same browser context at the given path, then close it. Used
    // (#100) where a test needs to reach a server-side effect scoped to a
    // *new* connection -- e.g. a test-only route whose entire purpose, on
    // the Lisp side, is triggered by that connection simply opening (see
    // e2e/test-hooks.lisp) -- without navigating the primary page under
    // test away from what the scenario is asserting on.
    case 'open_tab': {
      const tab = await page.context().newPage();
      try {
        await tab.goto(new URL(step.path, base).toString(), { waitUntil: 'load', timeout });
        // A generic settle window, not app-specific: this tab's own
        // client-side JS (e.g. a websocket handshake it kicks off on
        // load) may still be in flight right after the 'load' event
        // fires, and closing the tab mid-handshake can abort it entirely
        // server-side before it has any effect (#100).
        await tab.waitForTimeout(step.settle_ms ?? 500);
      } finally {
        await tab.close();
      }
      return;
    }
    case 'assert_url_pattern': return assert.match(new URL(page.url()).pathname, new RegExp(step.pattern));
    case 'assert_title': return assert.equal(await page.title(), step.value);
    case 'assert_active_id': return page.waitForFunction(
      (value) => document.activeElement?.id === value, step.value, { timeout });
    case 'assert_disabled': return assert.equal(await target().isDisabled(), Boolean(step.value));
    case 'wait_disabled': return page.waitForFunction(({ selector, value }) => document.querySelector(selector)?.disabled === Boolean(value), { selector: step.selector, value: step.value }, { timeout });
    case 'assert_value': return assert.equal(await target().inputValue(), step.value);
    case 'assert_input_pattern': return assert.match(await target().inputValue(), new RegExp(step.pattern));
    case 'assert_count': return assert.equal(await target().count(), step.count);
    case 'assert_text_count': return assert.equal(await target().filter({ hasText: step.text }).count(), step.count);
    case 'assert_text': return assert.equal(await target().innerText(), step.value);
    case 'assert_not_text': return assert.equal((await page.locator('body').innerText()).includes(step.value), false);
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
    case 'assert_attribute': return page.waitForFunction(
      ({ selector, name, value }) => document.querySelector(selector)?.getAttribute(name) === value,
      { selector: step.selector, name: step.name, value: step.value }, { timeout });
    case 'assert_overflow_fits': return assert.equal(await target().evaluate((node) => node.scrollWidth <= node.clientWidth), true);
    case 'assert_scrolled_to_bottom': return assert.equal(await target().evaluate((node) => Math.abs(node.scrollTop + node.clientHeight - node.scrollHeight) <= 2), true);
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
    for (const step of scenario.steps) await executeStep(page, base, step);
    await page.screenshot({ path: path.join(artifacts, `${scenario.name}-${scenario.evidence_suffix}.png`), fullPage: true });
    assert.deepEqual(errors, [], `${scenario.name}: unexpected browser errors`);
  } catch (error) {
    await page.screenshot({ path: path.join(artifacts, `${scenario.name}-${scenario.evidence_suffix}-failure.png`), fullPage: true });
    throw error;
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
