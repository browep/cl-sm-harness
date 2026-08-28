// Support script for the `show_image` catalog tool
// (sm-harness/src/tool-catalog.lisp) -- NOT part of the Playwright E2E
// suite itself. It lives here only to reuse this directory's already-
// provisioned `playwright` npm install (see docs/sm-harness-web-ui.md,
// "Running browser E2E without Docker": Chromium is baked into the image
// at /opt/ms-playwright and `npm ci` already ran for this package
// specifically so browser automation works in this container with no
// extra setup) rather than standing up a second copy of the same
// dependency elsewhere.
//
// Usage: node show-image-render.mjs <html-file-path> <output-png-path>
//
// Loads HTML-FILE-PATH (a local file:// page the Lisp caller already
// built, containing a single <img id="shown" src="..."> element),
// waits for that image to finish decoding, then screenshots exactly that
// element -- not the whole viewport -- to OUTPUT-PNG-PATH, so the result
// is cropped tightly to the image's own rendered bounds regardless of
// its dimensions.

import { chromium } from 'playwright';

async function main() {
  const [, , htmlPath, outPath] = process.argv;
  if (!htmlPath || !outPath) {
    console.error('usage: show-image-render.mjs <html-path> <out-png-path>');
    process.exitCode = 2;
    return;
  }

  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.goto('file://' + htmlPath);
    await page.waitForFunction(
      () => {
        const img = document.getElementById('shown');
        return !!img && img.complete && img.naturalWidth > 0;
      },
      { timeout: 15000 }
    );
    await page.locator('#shown').screenshot({ path: outPath });
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error(String((err && err.stack) || err));
  process.exitCode = 1;
});
