import {
  appendFileSync,
  closeSync,
  existsSync,
  fsyncSync,
  openSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

import { activeHalt, digest, mergeExecutions, newYorkDay, parseIntent, evaluatePlacement } from "./policy.mjs";
import { flattenOwned, freshUsdToEur, openSession, placeProtectiveBracket, publicSnapshot, resolveStock } from "./ib.mjs";

const STATE_PATH = process.env.IB_DESK_STATE || "/state/ledger.json";
const AUDIT_PATH = process.env.IB_DESK_AUDIT || "/state/audit.jsonl";
const LOCAL_HALT_PATH = process.env.IB_DESK_LOCAL_HALT || "/state/HALT";
const OWNERSHIP_LEDGER = process.env.IB_DESK_OWNERSHIP_LEDGER || "/pusher-state/execution-history.json";
const REPOSITORY = process.env.IB_DESK_GITHUB_REPOSITORY || "markus-barta/oc-workspace-shared";
const INTENT_LABEL = "hsb0-paper-intent";
const HALT_LABEL = "hsb0-paper-halt";
const ALLOWED_ACTOR = "markus-barta";

function parseMap(name) {
  const value = JSON.parse(process.env[name] || "{}");
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${name} is invalid`);
  return value;
}

const CLIENT_IDS = parseMap("IB_DESK_CLIENT_IDS");
const OWNERSHIP_CLIENT_IDS = parseMap("IB_DESK_OWNERSHIP_CLIENT_IDS");

function initialState() {
  return {
    schema: "barta.paper-desk-runner-state.v1",
    account: "DUR970597",
    initializedAt: new Date().toISOString(),
    intents: {},
    placements: [],
    executions: [],
  };
}

function loadState() {
  if (!existsSync(STATE_PATH)) {
    const state = initialState();
    saveState(state);
    audit({ event: "ledger_initialized", initializedAt: state.initializedAt });
    return state;
  }
  const value = JSON.parse(readFileSync(STATE_PATH, "utf8"));
  if (value?.schema !== "barta.paper-desk-runner-state.v1" || value?.account !== "DUR970597"
      || !Number.isFinite(Date.parse(value.initializedAt)) || !value.intents
      || !Array.isArray(value.placements) || !Array.isArray(value.executions)) {
    throw new Error("runner state is invalid");
  }
  return value;
}

function saveState(state) {
  const temporary = `${STATE_PATH}.new`;
  const body = `${JSON.stringify(state, null, 2)}\n`;
  const handle = openSync(temporary, "w", 0o600);
  try {
    writeFileSync(handle, body);
    fsyncSync(handle);
  } finally {
    closeSync(handle);
  }
  renameSync(temporary, STATE_PATH);
  const directory = openSync(path.dirname(STATE_PATH), "r");
  try { fsyncSync(directory); } finally { closeSync(directory); }
}

function audit(event) {
  const row = `${JSON.stringify({ at: new Date().toISOString(), ...event })}\n`;
  const handle = openSync(AUDIT_PATH, "a", 0o600);
  try {
    appendFileSync(handle, row);
    fsyncSync(handle);
  } finally {
    closeSync(handle);
  }
}

function localHaltBody() {
  try { return readFileSync(LOCAL_HALT_PATH, "utf8"); } catch (error) {
    if (error?.code === "ENOENT") return "";
    throw error;
  }
}

function publicError(error) {
  return String(error?.message || error).slice(0, 500);
}

function extractJson(body) {
  const source = String(body || "").trim();
  const match = source.match(/^```(?:json)?\s*\n([\s\S]*?)\n```$/i);
  return JSON.parse(match ? match[1] : source);
}

class GitHub {
  constructor(token) {
    this.token = token;
    this.base = `https://api.github.com/repos/${REPOSITORY}`;
  }

  async request(method, url, body) {
    const response = await fetch(url.startsWith("http") ? url : `${this.base}${url}`, {
      method,
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${this.token}`,
        "Content-Type": "application/json",
        "User-Agent": "hsb0-paper-desk-runner/1",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok) throw new Error(`GitHub ${method} ${response.status}`);
    if (response.status === 204) return null;
    return response.json();
  }

  async verifyPrivate() {
    const repository = await this.request("GET", "");
    if (repository.private !== true || repository.full_name !== REPOSITORY) {
      throw new Error("intent queue must be the configured private repository");
    }
  }

  list(label) {
    return this.request("GET", `/issues?state=open&labels=${encodeURIComponent(label)}&sort=created&direction=asc&per_page=50`);
  }

  comment(number, result) {
    const rendered = JSON.stringify(result, null, 2);
    return this.request("POST", `/issues/${number}/comments`, { body: `\`\`\`json\n${rendered}\n\`\`\`` });
  }

  close(number) {
    return this.request("PATCH", `/issues/${number}`, { state: "closed" });
  }
}

function issueIdentity(issue) {
  if (issue.pull_request) throw new Error("pull requests are not intents");
  if (issue.user?.login !== ALLOWED_ACTOR || !["OWNER", "MEMBER", "COLLABORATOR"].includes(issue.author_association)) {
    throw new Error("issue actor is not authorized");
  }
  if (!(issue.labels || []).some((label) => label.name === INTENT_LABEL)) throw new Error("intent label is missing");
}

function claim(state, intent, issueNumber) {
  const hash = digest(intent);
  const prior = state.intents[intent.intentId];
  if (prior) {
    if (prior.hash !== hash) throw new Error("intentId was already used with different content");
    return { duplicate: true, prior };
  }
  state.intents[intent.intentId] = {
    hash,
    issueNumber,
    action: intent.action,
    desk: intent.desk,
    status: "claimed",
    claimedAt: new Date().toISOString(),
  };
  saveState(state);
  audit({ event: "intent_claimed", intentId: intent.intentId, issueNumber, action: intent.action, desk: intent.desk, hash });
  return { duplicate: false, prior: null };
}

function finish(state, intent, status, result) {
  state.intents[intent.intentId] = {
    ...state.intents[intent.intentId],
    status,
    finishedAt: new Date().toISOString(),
    result,
  };
  saveState(state);
  audit({ event: "intent_finished", intentId: intent.intentId, status, result });
}

function mergeCapturedExecutions(state, rows) {
  state.executions = mergeExecutions(state.executions, rows);
  saveState(state);
}

async function executeIntent(intent, state, halt) {
  const clientId = Number(CLIENT_IDS[intent.desk]);
  if (!Number.isSafeInteger(clientId)) throw new Error("desk has no dedicated client ID");
  if (intent.action === "recon") {
    const session = await openSession(Number(CLIENT_IDS.recon));
    try {
      mergeCapturedExecutions(state, session.state.executions);
      return { status: "ok", intentId: intent.intentId, desk: intent.desk, action: "recon", observedAt: new Date().toISOString(), ...publicSnapshot(session.state) };
    } finally {
      session.close();
    }
  }
  if (intent.action === "flatten") {
    const outcome = await flattenOwned({
      desk: intent.desk,
      clientId,
      ownershipClientIds: OWNERSHIP_CLIENT_IDS[intent.desk] || [],
      stateExecutions: state.executions,
      ownershipLedgerFile: OWNERSHIP_LEDGER,
      intentId: intent.intentId,
    });
    state.executions = outcome.executions;
    saveState(state);
    const { executions: _privateExecutions, ...result } = outcome;
    return { status: "ok", intentId: intent.intentId, action: "flatten", observedAt: new Date().toISOString(), haltIgnoredForFlatten: halt.active, ...result };
  }

  const session = await openSession(Number(CLIENT_IDS.recon));
  try {
    mergeCapturedExecutions(state, session.state.executions);
    const resolved = await resolveStock(session, intent.order.symbol);
    const usdToEur = await freshUsdToEur(session);
    const budget = evaluatePlacement(intent, publicSnapshot(session.state), state, {
      halt: halt.active,
      stockType: resolved.stockType,
      usdToEur,
    });
    const placement = {
      intentId: intent.intentId,
      desk: intent.desk,
      clientId,
      symbol: intent.order.symbol,
      day: budget.day,
      riskEur: budget.riskEur,
      notionalEur: budget.notionalEur,
      status: "reserved",
      reservedAt: new Date().toISOString(),
    };
    state.placements.push(placement);
    saveState(state);
    const placingSession = await openSession(clientId);
    try {
      const placed = await placeProtectiveBracket(placingSession, { ...intent, clientId }, resolved);
      placement.status = "submitted";
      placement.orderIds = [placed.parentOrderId, placed.stopOrderId];
      placement.submittedAt = new Date().toISOString();
      mergeCapturedExecutions(state, placingSession.state.executions);
      saveState(state);
      return {
        status: "ok",
        intentId: intent.intentId,
        desk: intent.desk,
        action: "place",
        observedAt: new Date().toISOString(),
        paperPort: 4002,
        account: "DUR970597",
        contract: { conId: resolved.contract.conId, symbol: resolved.contract.symbol, stockType: resolved.stockType },
        budget,
        bracket: placed,
      };
    } catch (error) {
      placement.status = "uncertain";
      placement.error = publicError(error);
      saveState(state);
      throw new Error(`placement outcome uncertain; reconcile before any retry: ${publicError(error)}`);
    } finally {
      placingSession.close();
    }
  } finally {
    session.close();
  }
}

async function rejectIssue(github, issue, reason) {
  const result = { status: "rejected", issue: issue.number, observedAt: new Date().toISOString(), reason };
  audit({ event: "issue_rejected", issueNumber: issue.number, reason });
  await github.comment(issue.number, result);
  await github.close(issue.number);
}

async function processIssue(github, issue, state, halt) {
  let intent;
  try {
    issueIdentity(issue);
    intent = parseIntent(extractJson(issue.body));
  } catch (error) {
    await rejectIssue(github, issue, publicError(error));
    return;
  }
  let claimed;
  try {
    claimed = claim(state, intent, issue.number);
  } catch (error) {
    await rejectIssue(github, issue, publicError(error));
    return;
  }
  if (claimed.duplicate) {
    const result = claimed.prior.result || {
      status: "uncertain",
      intentId: intent.intentId,
      reason: "intent was claimed before a durable result; no automatic replay is allowed",
    };
    await github.comment(issue.number, { ...result, idempotentReplay: true });
    await github.close(issue.number);
    return;
  }
  try {
    const result = await executeIntent(intent, state, halt);
    finish(state, intent, "done", result);
    await github.comment(issue.number, result);
  } catch (error) {
    const result = {
      status: "rejected",
      intentId: intent.intentId,
      desk: intent.desk,
      action: intent.action,
      observedAt: new Date().toISOString(),
      reason: publicError(error),
    };
    finish(state, intent, "rejected", result);
    await github.comment(issue.number, result);
  }
  await github.close(issue.number);
}

function readToken() {
  const tokenFile = process.env.IB_DESK_GITHUB_TOKEN_FILE;
  if (!tokenFile) throw new Error("GitHub token credential is not configured");
  const token = readFileSync(tokenFile, "utf8").trim();
  if (!token) throw new Error("GitHub token credential is empty");
  return token;
}

async function poll() {
  const github = new GitHub(readToken());
  await github.verifyPrivate();
  const [issues, haltIssues] = await Promise.all([github.list(INTENT_LABEL), github.list(HALT_LABEL)]);
  const halt = activeHalt(localHaltBody(), haltIssues);
  const state = loadState();
  audit({ event: "poll", issueCount: issues.length, halt });
  for (const issue of issues) await processIssue(github, issue, state, halt);
  console.log(JSON.stringify({ event: "poll_complete", issueCount: issues.length, halt }));
}

async function scheduledFlatten(desk) {
  if (!OWNERSHIP_CLIENT_IDS[desk]) throw new Error("scheduled flatten desk is invalid");
  const state = loadState();
  const intentId = `scheduled-${desk}-${newYorkDay()}`;
  if (state.intents[intentId]) {
    console.log(JSON.stringify({ event: "scheduled_flatten_idempotent", intentId, result: state.intents[intentId].result || null }));
    return;
  }
  const intent = { intentId, desk, action: "flatten" };
  state.intents[intentId] = {
    hash: digest(intent),
    issueNumber: null,
    action: "flatten",
    desk,
    status: "claimed",
    claimedAt: new Date().toISOString(),
  };
  saveState(state);
  audit({ event: "intent_claimed", intentId, issueNumber: null, action: "flatten", desk });
  try {
    const result = await executeIntent(intent, state, activeHalt(localHaltBody(), []));
    finish(state, intent, "done", result);
    console.log(JSON.stringify({ event: "scheduled_flatten_complete", ...result }));
  } catch (error) {
    const result = { status: "rejected", intentId, desk, action: "flatten", observedAt: new Date().toISOString(), reason: publicError(error) };
    finish(state, intent, "rejected", result);
    console.error(JSON.stringify({ event: "scheduled_flatten_failed", ...result }));
    process.exitCode = 1;
  }
}

const [command, argument] = process.argv.slice(2);
if (command === "poll") await poll();
else if (command === "scheduled-flatten") await scheduledFlatten(argument);
else throw new Error("usage: runner.mjs poll | scheduled-flatten DESK");
