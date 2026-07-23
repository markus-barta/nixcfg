import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:http";
import test from "node:test";

import { chromium } from "playwright";

import {
  createRequestStageNavigationGuard,
  resolveBrowserExecutable,
} from "./target-policy.mjs";

test("blocks a redirect escape before the destination receives a request", async () => {
  let destinationRequests = 0;
  const destination = createServer((_request, response) => {
    destinationRequests += 1;
    response.end("boundary bypassed");
  });
  destination.listen(0, "127.0.0.1");
  await once(destination, "listening");

  let browser;
  try {
    const address = destination.address();
    assert(address && typeof address === "object");
    const hostileTarget = `http://127.0.0.1:${address.port}/admin`;
    const fixtureTarget = "https://www.hausv.org/__nix315_redirect_fixture__";
    const executablePath = await resolveBrowserExecutable(
      process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
    );

    browser = await chromium.launch({ headless: true, executablePath });
    const context = await browser.newContext({ serviceWorkers: "block" });
    const page = await context.newPage();
    const cdp = await context.newCDPSession(page);
    const blocked = [];
    const guardNavigation = createRequestStageNavigationGuard(
      (...args) => cdp.send(...args),
      (error) => blocked.push(error),
    );

    cdp.on("Fetch.requestPaused", (event) => {
      void (async () => {
        if (event.request.url === fixtureTarget) {
          await cdp.send("Fetch.fulfillRequest", {
            requestId: event.requestId,
            responseCode: 302,
            responseHeaders: [{ name: "Location", value: hostileTarget }],
          });
          return;
        }
        await guardNavigation(event);
      })();
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

    await assert.rejects(page.goto(fixtureTarget));
    assert.equal(blocked.length, 1);
    assert.match(blocked[0].message, /127\.0\.0\.1/);
    assert.equal(destinationRequests, 0);
  } finally {
    await browser?.close();
    await new Promise((resolve, reject) => {
      destination.close((error) => (error ? reject(error) : resolve()));
    });
  }
});
