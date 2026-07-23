// This template intentionally uses a source-controlled allowlist. Consumers
// should replace these origins when copying the template into another repo;
// do not derive the boundary from CLI arguments or environment variables.
export const ALLOWED_TARGET_ORIGINS = Object.freeze([
  "https://hausv.org",
  "https://www.hausv.org",
]);

const ALLOWED_TARGET_SCHEMES = new Set(["http:", "https:"]);
const DARWIN_CHROME =
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
// Nix store objects are immutable. Keep selection lexical and let Playwright
// report a missing executable instead of probing an environment-derived path.
const NIX_CHROMIUM =
  /^(\/nix\/store\/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^/]+)\/bin\/(?:chromium|chromium-browser)$/;

export function validateTarget(rawTarget) {
  if (typeof rawTarget !== "string" || rawTarget.length === 0) {
    throw new Error("A screenshot target URL is required.");
  }

  let target;
  try {
    target = new URL(rawTarget);
  } catch {
    throw new Error(
      `Invalid screenshot target URL: ${JSON.stringify(rawTarget)}`,
    );
  }

  if (!ALLOWED_TARGET_SCHEMES.has(target.protocol)) {
    throw new Error(
      `Screenshot target scheme ${JSON.stringify(target.protocol)} is not allowed; use http or https.`,
    );
  }

  if (target.username || target.password) {
    throw new Error("Screenshot target URLs must not contain credentials.");
  }

  if (!ALLOWED_TARGET_ORIGINS.includes(target.origin)) {
    throw new Error(
      `Screenshot target origin ${JSON.stringify(target.origin)} is outside the source-controlled allowlist.`,
    );
  }

  return target;
}

export function selectBrowserExecutable(rawPath) {
  if (typeof rawPath !== "string" || rawPath.length === 0) {
    throw new Error(
      "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH is not set — enter the devenv shell first (direnv allow).",
    );
  }

  if (rawPath === DARWIN_CHROME) {
    return DARWIN_CHROME;
  }

  if (!NIX_CHROMIUM.test(rawPath)) {
    throw new Error(
      "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH must be the declarative macOS Chrome path or a nix-store Chromium executable.",
    );
  }

  return rawPath;
}

export function createRequestStageNavigationGuard(send, onBlocked) {
  return async (event) => {
    try {
      validateTarget(event.request.url);
      await send("Fetch.continueRequest", { requestId: event.requestId });
    } catch (error) {
      onBlocked(error);
      await send("Fetch.failRequest", {
        requestId: event.requestId,
        errorReason: "BlockedByClient",
      });
    }
  };
}
