import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { discoverScenarioNames, loadContract, runScenario } from './bridge.mjs';

const base = process.env.BASE_URL || 'http://127.0.0.1:8080';
const artifacts = process.env.ARTIFACTS || './artifacts';
const here = path.dirname(fileURLToPath(import.meta.url));
fs.mkdirSync(artifacts, { recursive: true });

const browser = await chromium.launch({ headless: true });
try {
  const contract = await loadContract(base);
  const markers = new Set(discoverScenarioNames(path.join(here, 'tests')));
  const requested = process.env.E2E_SCENARIO
    ? [process.env.E2E_SCENARIO]
    : contract.map((scenario) => scenario.name).filter((name) => markers.has(name));
  for (const name of requested) {
    const scenario = contract.find((item) => item.name === name);
    if (!scenario) throw new Error(`Lisp E2E contract has no scenario named ${name}`);
    await runScenario(browser, base, artifacts, scenario);
  }
  console.log(`e2e contract scenarios completed: ${requested.join(', ')}`);
} finally {
  await browser.close();
}
