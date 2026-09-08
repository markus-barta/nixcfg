#!/usr/bin/env node
// Headless screenshot / smoke test via Playwright, driving the system Chromium
// pointed to by $PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH (set by devenv.nix).
// Origin: nixcfg NIX-288.
//
// NIX-445: inside a guarded agent session that variable points at
// `inspr-browser-guard-refuse`, which refuses and exits 78 — agent worker
// sessions must not start a native browser on the operator's Mac. That refusal
// is NOT a passed test: report it and ask the controller for a verified runner
// instead of retrying or looking for another browser binary. This template is
// itself the native-browser path the guard blocks, so it is not the safe runner.
//
// Usage (inside the devenv shell):
//   node screenshot.mjs [url] [outfile]
//   node screenshot.mjs https://www.hausv.org/ hausv.png
import { chromium } from "playwright";
import {
  createRequestStageNavigationGuard,
  selectBrowserExecutable,
  validateTarget,
} from "./target-policy.mjs";

const target = validateTarget(process.argv[2] ?? "https://www.hausv.org/");
const out = process.argv[3] ?? "screenshot.png";
const executablePath = selectBrowserExecutable(
  process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
);

const browser = await chromium.launch({ headless: true, executablePath });
try {
  const context = await browser.newContext({
    serviceWorkers: "block",
    viewport: { width: 1280, height: 800 },
  });
  let blockedNavigation;
  const page = await context.newPage();

  // Playwright route handlers only see the first URL in a redirect chain.
  // CDP Fetch pauses every document hop before it reaches the network.
  const cdp = await context.newCDPSession(page);
  const guardNavigation = createRequestStageNavigationGuard(
    (...args) => cdp.send(...args),
    (error) => {
      blockedNavigation ??= error;
    },
  );
  cdp.on("Fetch.requestPaused", (event) => {
    void guardNavigation(event).catch(async (error) => {
      blockedNavigation ??= error;
      await cdp
        .send("Fetch.failRequest", {
          requestId: event.requestId,
          errorReason: "Failed",
        })
        .catch(() => {});
    });
  });
  await cdp.send("Fetch.enable", {
    patterns: [
      {
        urlPattern: "*",
        resourceType: "Document",
        requestStage: "Request",
      },
    ],
  });

  let resp;
  try {
    resp = await page.goto(target.href, {
      waitUntil: "networkidle",
      timeout: 30_000,
    });
  } catch (error) {
    throw blockedNavigation ?? error;
  }

  if (blockedNavigation) {
    throw blockedNavigation;
  }

  const finalTarget = validateTarget(page.url());
  await page.screenshot({ path: out, fullPage: true });
  console.log(
    `✅ ${finalTarget.href} → ${out} (HTTP ${resp?.status() ?? "??"}, title: ${JSON.stringify(await page.title())})`,
  );
} finally {
  await browser.close();
}
