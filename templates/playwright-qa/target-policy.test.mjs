import assert from "node:assert/strict";
import test from "node:test";

import {
  createRequestStageNavigationGuard,
  validateBrowserExecutableCandidate,
  validateTarget,
} from "./target-policy.mjs";

test("accepts only the source-controlled target origins", () => {
  assert.equal(
    validateTarget("https://www.hausv.org/path?q=1#result").href,
    "https://www.hausv.org/path?q=1#result",
  );
  assert.equal(
    validateTarget("HTTPS://HAUSV.ORG:443/").href,
    "https://hausv.org/",
  );
});

test("rejects unsupported schemes and URL credentials", () => {
  assert.throws(() => validateTarget("file:///etc/passwd"), /scheme/);
  assert.throws(
    () => validateTarget("https://user:secret@www.hausv.org/"),
    /credentials/,
  );
});

test("rejects lookalike, alternate-port, and encoded hostile origins", () => {
  for (const target of [
    "https://www.hausv.org.evil.test/",
    "https://www.hausv.org@evil.test/",
    "https://evil.test/%2f%2fwww.hausv.org/",
    "https://%65%76%69%6c.test/",
    "https://www.hausv.org:444/",
    "http://www.hausv.org/",
    "http://2130706433/",
    "http://0x7f000001/",
  ]) {
    assert.throws(() => validateTarget(target), /allowlist|credentials/);
  }
});

test("accepts only declarative browser executable shapes", () => {
  const darwin = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const nix =
    "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-chromium-130.0/bin/chromium";

  assert.equal(validateBrowserExecutableCandidate(darwin).candidate, darwin);
  assert.equal(validateBrowserExecutableCandidate(nix).candidate, nix);
});

test("rejects browser executable path escapes and lookalikes", () => {
  for (const executable of [
    "",
    "chromium",
    "/tmp/chromium",
    "/nix/store/not-a-store-hash-chromium/bin/chromium",
    "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-chromium/bin/chromium/../../evil",
    "/Applications/Google Chrome Evil.app/Contents/MacOS/Google Chrome",
  ]) {
    assert.throws(() => validateBrowserExecutableCandidate(executable));
  }
});

test("request-stage guard permits allowed targets and blocks redirect escapes", async () => {
  const commands = [];
  const blocked = [];
  const guard = createRequestStageNavigationGuard(
    async (method, params) => commands.push({ method, params }),
    (error) => blocked.push(error.message),
  );

  await guard({
    requestId: "initial",
    request: { url: "https://www.hausv.org/" },
  });
  await guard({
    requestId: "redirect",
    request: { url: "http://127.0.0.1:3000/admin" },
  });

  assert.deepEqual(commands, [
    {
      method: "Fetch.continueRequest",
      params: { requestId: "initial" },
    },
    {
      method: "Fetch.failRequest",
      params: {
        requestId: "redirect",
        errorReason: "BlockedByClient",
      },
    },
  ]);
  assert.equal(blocked.length, 1);
  assert.match(blocked[0], /allowlist/);
});
