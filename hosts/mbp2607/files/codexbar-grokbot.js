// CodexBar provider plugin — Grok Bot (xAI) weekly usage.
//
// Surfaces the "Weekly usage" meter that the Grok Bot desktop app shows in its
// account menu. Grok Bot is a rebranded Cursor client, so the meter is served by
// Cursor's dashboard API ("sand" is Anysphere's internal codename for it) and is
// authenticated with the cursor.com browser session — NOT with xAI credentials.
//
// Verified 2026-08-28 against CodexBar 0.56.0 / Grok Bot 1.0.5 on mbp2607.
//
// Response shape of POST https://cursor.com/api/dashboard/get-sand-usage-status:
//   {
//     "currentPeriodStart":      "2026-08-26T17:22:03.913Z",  ISO-8601 UTC
//     "nextResetTimestampUtc":   "2026-09-01T19:28:16.957Z",  ISO-8601 UTC
//     "usagePercent":            78.814712,                   <- the meter
//     "hasAvailableUsage":       true,
//     "hasNonZeroIncludedLimit": true,
//     "onDemandSettings": { "visible": true, "eligible": true, "dashboardUrl": "..." },
//     "grokPlanLabel":           "Grok Bot Plan"
//   }
//
// Design rule: an ABSENT usagePercent must never render as 0%. Every unknown
// state raises a classified failure so CodexBar shows an error, not a number.

const USAGE_URL = "https://cursor.com/api/dashboard/get-sand-usage-status";
const COOKIE_DOMAIN = "cursor.com";
const SESSION_COOKIE = "WorkosCursorSessionToken";
// Fallback for when CodexBar cannot read the browser cookie jar. Helium stores
// its Chromium key under the Keychain service "Helium Storage Key", which is not
// one of the "<Browser> Safe Storage" names CodexBar looks for, so browser-cookie
// access can fail on this host even though the session exists.
const COOKIE_SETTING = "GROKBOT_CURSOR_COOKIE";
// Grok Bot's included allowance runs on a ~weekly window (8766 minutes is what
// Cursor itself reports for this pool). Kept explicit so the dropdown labels it.
const WINDOW_MINUTES = 8766;

defineProvider({
  id: "grokbot",
  name: "Grok Bot",
  endpoints: ["https://cursor.com"],
  settings: [
    {
      key: COOKIE_SETTING,
      title: "cursor.com Cookie header (fallback)",
      type: "secure",
    },
  ],
  capabilities: ["browser-cookies"],
  cookieDomains: [COOKIE_DOMAIN],

  async fetchUsage(ctx) {
    // --- credential ------------------------------------------------------
    let cookie = "";
    let cookieSource = "browser";
    try {
      cookie = (await ctx.browser.cookieHeader(COOKIE_DOMAIN)) || "";
    } catch {
      cookie = "";
    }
    if (!cookie.includes(SESSION_COOKIE)) {
      // Browser jar unreadable or signed out — fall back to a pasted header.
      let stored = "";
      try {
        stored = (await ctx.settings.getSecret(COOKIE_SETTING)) || "";
      } catch {
        stored = "";
      }
      if (stored.includes(SESSION_COOKIE)) {
        cookie = stored;
        cookieSource = "setting";
      }
    }
    if (!cookie) {
      throw ctx.fail.missingCredential(
        `No ${COOKIE_DOMAIN} cookies available. Sign in to cursor.com in a supported browser, ` +
          `or paste a Cookie header into the ${COOKIE_SETTING} setting.`,
      );
    }
    if (!cookie.includes(SESSION_COOKIE)) {
      throw ctx.fail.missingCredential(
        `${COOKIE_DOMAIN} session cookie ${SESSION_COOKIE} is absent. Sign in to cursor.com again, ` +
          `or paste a current Cookie header into the ${COOKIE_SETTING} setting.`,
      );
    }

    // --- fetch -----------------------------------------------------------
    let response;
    try {
      response = await ctx.http.postJSON(USAGE_URL, {
        body: {},
        headers: {
          Cookie: cookie,
          Origin: "https://cursor.com",
          Referer: "https://cursor.com/dashboard",
        },
        timeoutSeconds: 8,
      });
    } catch (error) {
      throw ctx.fail.networkFailure(
        `Request to cursor.com failed: ${error && error.message ? error.message : error}`,
        { retryAfterSeconds: 60 },
      );
    }

    const status = response.status;
    if (status === 401 || status === 403) {
      throw ctx.fail.authenticationExpired(
        `cursor.com rejected the ${cookieSource} session (HTTP ${status}). Sign in to cursor.com again.`,
      );
    }
    if (status === 429) {
      throw ctx.fail.rateLimited("cursor.com rate limited the usage request.", {
        retryAfterSeconds: 120,
      });
    }
    if (status >= 500) {
      throw ctx.fail.providerUnavailable(
        `cursor.com returned HTTP ${status}.`,
        { retryAfterSeconds: 120 },
      );
    }
    if (status !== 200) {
      throw ctx.fail.apiFailure(`cursor.com returned HTTP ${status}.`, {
        retryAfterSeconds: 60,
      });
    }

    // --- parse -----------------------------------------------------------
    const data = response.json;
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw ctx.fail.parseFailure(
        `Usage response was not a JSON object (HTTP ${status}).`,
      );
    }

    // Absent is NOT zero. Distinguish the two explicitly.
    if (!Object.prototype.hasOwnProperty.call(data, "usagePercent")) {
      throw ctx.fail.parseFailure(
        `Usage response (HTTP ${status}) has no "usagePercent" field — the API schema likely changed.`,
      );
    }
    const rawPercent = data.usagePercent;
    if (rawPercent === null) {
      throw ctx.fail.parseFailure(
        `"usagePercent" was null (HTTP ${status}) — usage is unknown, not zero.`,
      );
    }
    const usedPercent = Number(rawPercent);
    if (!Number.isFinite(usedPercent)) {
      throw ctx.fail.parseFailure(
        `"usagePercent" was not a finite number: ${JSON.stringify(rawPercent)}.`,
      );
    }

    // Reset timestamp is best-effort: a missing one degrades the label, it does
    // not invalidate a percentage we successfully read.
    let resetsAt;
    if (data.nextResetTimestampUtc) {
      try {
        resetsAt = ctx.date.iso(data.nextResetTimestampUtc);
      } catch {
        resetsAt = undefined;
      }
    }

    const primary = {
      usedPercent,
      windowMinutes: WINDOW_MINUTES,
      resetDescription: "Weekly usage",
    };
    if (resetsAt) primary.resetsAt = resetsAt;

    const details = [];
    if (data.currentPeriodStart) {
      try {
        details.push({
          label: "Period start",
          value: ctx.format.monthDay(ctx.date.iso(data.currentPeriodStart)),
        });
      } catch {
        /* a malformed start date is cosmetic — skip the row */
      }
    }
    if (data.hasAvailableUsage === false) {
      details.push({ label: "Included allowance", value: "exhausted" });
    }

    const result = {
      primary,
      identity: {
        loginMethod:
          typeof data.grokPlanLabel === "string"
            ? data.grokPlanLabel
            : "Grok Bot",
      },
    };
    if (details.length > 0) result.details = details;
    return result;
  },
});
