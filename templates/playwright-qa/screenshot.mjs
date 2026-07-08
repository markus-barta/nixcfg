#!/usr/bin/env node
// Headless screenshot / smoke test via Playwright, driving the system Chromium
// pointed to by $PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH (set by devenv.nix).
// Origin: nixcfg NIX-288.
//
// Usage (inside the devenv shell):
//   node screenshot.mjs [url] [outfile]
//   node screenshot.mjs https://www.hausv.org/ hausv.png
import { chromium } from 'playwright';

const url = process.argv[2] ?? 'https://www.hausv.org/';
const out = process.argv[3] ?? 'screenshot.png';
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;

if (!executablePath) {
  console.error(
    'PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH is not set — enter the devenv shell first (direnv allow).',
  );
  process.exit(1);
}

const browser = await chromium.launch({ headless: true, executablePath });
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const resp = await page.goto(url, { waitUntil: 'networkidle', timeout: 30_000 });
  await page.screenshot({ path: out, fullPage: true });
  console.log(
    `✅ ${url} → ${out} (HTTP ${resp?.status() ?? '??'}, title: ${JSON.stringify(await page.title())})`,
  );
} finally {
  await browser.close();
}
