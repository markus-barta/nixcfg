import fs from "node:fs";
import path from "node:path";
import net from "node:net";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { verify } from "./verify-contracts.mjs";
import { FRAME_FORMAT, MAX_FRAME_BYTES } from "./v2-stage-handoff.mjs";
import { validCycle, cycleId, cycleReceipt, validCycleReceipt, receiptBinding, frame } from "./v1-cycle.mjs";
import { DESK_IDS, DESK_ACTION, EXECUTION_CAUSES, ACTIVITY_FRESH_MS, deskState } from "./desk-activity.mjs";
import { contractRevision, validExactValues, applyExactValues, exactDeskAction, MONEY_FIELDS } from "./v2-exact-values.mjs";

export const STATE_DIR = "/var/lib/joe-board-pusher/v2";
export const SOCKET_PATH = "/run/joe-household-v2/stage.sock";
export const CONTRACT_SHA = "3a9e1ae4ff24e063c38d6b7f77844ec03e03c9602d84421393010efacf244350";
const REV9_SHA = "000045fb7843a16be95f6a7e42d46d4b4ecb34b0efd39fc987bee444817fc9d5";
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
export const RETAIN_PAIRS = 10;
const MAX_RETAIN_PAIRS = 1024;
const logFormat = "ops392.v2-sequence-receipt.v1";
const stateFormat = "ops392.v2-sequence-state.v1";
const pairFormat = "ops392.v2-stage-pair.v1";
const pointerFormat = "ops392.v2-stage-current.v1";
const checkpointFormat = "joed102.v2-receipts-checkpoint.v1";
const checkpointSharedReadOnlyDirs = ["/var/lib/paper-desk-executor", "/run/secrets"];
const scanCheckpointBytes = 4 * 1024 * 1024;
const fail = () => { throw new Error("stage_storage_invalid"); };
const exactKeys = (value, keys) => value && typeof value === "object" && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify(keys.split(",").sort());
const positiveSeq = n => Number.isSafeInteger(n) && n > 0;

export function normalizeBookTs(value) {
  if (typeof value !== "string" || value.length > 64) return null;
  // The source publishes UTC ISO instants. Reject Date.parse's calendar rollover.
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/.exec(value);
  if (!match) return null;
  const normalized = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}.${(match[7] || "").padEnd(3, "0")}Z`;
  const date = new Date(normalized);
  return Number.isFinite(date.getTime()) && date.toISOString() === normalized ? normalized : null;
}
const canonical = value => typeof value === "string" && normalizeBookTs(value) === value;
const freeze = value => {
  if (value && typeof value === "object") { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
};
const observationId = instant => JSON.stringify(["ops392.switch-set.v2", instant]);

export function validObservation(value) {
  const raw = item => item === null || (exactKeys(item, "value,currency") && typeof item.value === "string"
    && item.value.length <= 32 && typeof item.currency === "string" && item.currency.length <= 3);
  const activity = value?.deskActivity;
  const validActivity = activity === undefined || (exactKeys(activity, "j,joe,joel") && DESK_IDS.every(id => {
    const row = activity[id];
    const failure = row?.executionCause;
    const validFailure = failure === undefined || (EXECUTION_CAUSES.includes(failure?.cause)
      && exactKeys(failure, failure.clientId === undefined ? "cause" : "cause,clientId")
      && (failure.clientId === undefined || (failure.cause === "execution_unowned"
        && Number.isSafeInteger(failure.clientId) && failure.clientId >= 0)));
    return validFailure && exactKeys(row, "positionsAt,hasPositions,ordersAt,hasOrders,executionsAt,executionDay,lastExecutionAt"
      + (failure === undefined ? "" : ",executionCause"))
      && [row.positionsAt, row.ordersAt, row.executionsAt, row.lastExecutionAt].every(at => at === null || canonical(at))
      && typeof row.hasPositions === "boolean" && typeof row.hasOrders === "boolean"
      && (row.executionDay === null || (typeof row.executionDay === "string" && /^\d{4}-\d{2}-\d{2}$/.test(row.executionDay)));
  }));
  return validActivity && (value?.exactValues === undefined || validExactValues(value.exactValues, value.positions?.length))
    && (value?.v1Cycle === undefined || validCycle(value.v1Cycle))
    && (value?.sourceObservedAt === undefined || (exactKeys(value.sourceObservedAt, "equity,cash,positions")
      && Object.values(value.sourceObservedAt).every(at => at === null || canonical(at))))
    && exactKeys(value, "format,bookTs,equity,cash,apiReplyCheckedAt,positions"
      + (value.sourceObservedAt === undefined ? "" : ",sourceObservedAt")
      + (activity === undefined ? "" : ",deskActivity") + (value.v1Cycle === undefined ? "" : ",v1Cycle")
      + (value.exactValues === undefined ? "" : ",exactValues")) && value.format === FRAME_FORMAT
    && typeof value.bookTs === "string" && value.bookTs.length <= 64 && raw(value.equity) && raw(value.cash)
    && (value.apiReplyCheckedAt === null || canonical(value.apiReplyCheckedAt))
    && Array.isArray(value.positions) && value.positions.length <= 256 && value.positions.every(row =>
      exactKeys(row, "symbol,side,desk,scope") && typeof row.symbol === "string" && /^[A-Z0-9][A-Z0-9._-]{0,15}$/.test(row.symbol)
      && ["long", "short"].includes(row.side) && [null, "j", "joe", "joel"].includes(row.desk)
      && row.scope === (["SXR8", "TSLA"].includes(row.symbol) ? "keep" : "stage0")
      && (row.scope !== "keep" || row.desk === null));
}

export function buildCandidate(seq, generatedAt, observation = {}, receivedAt = generatedAt, highWater = null, revision = 9) {
  // The source clock stays separate from the advancing envelope clock.
  const bookAt = normalizeBookTs(observation.bookTs);
  const sourceAt = field => observation.sourceObservedAt === undefined ? bookAt
    : normalizeBookTs(observation.sourceObservedAt?.[field]);
  const sourceFresh = at => {
    const age = Date.parse(generatedAt) - Date.parse(at);
    return Number.isFinite(age) && age >= 0 && age <= ACTIVITY_FRESH_MS;
  };
  const checkedAt = observation.apiReplyCheckedAt;
  let gateway;
  if (canonical(checkedAt)) {
    const age = Date.parse(generatedAt) - Date.parse(checkedAt);
    const receiptAge = Date.parse(receivedAt) - Date.parse(checkedAt);
    const reason = (age < 0 || receiptAge < 0) ? "clock_ahead"
      : highWater && checkedAt < highWater ? "clock_regressed"
        : age > ACTIVITY_FRESH_MS || receiptAge > ACTIVITY_FRESH_MS ? "snapshot_stale"
          : age >= 60000 || receiptAge >= 60000 ? "gateway_unconfirmed" : null;
    gateway = { apiSessionReady: !reason, checkedAt, ...(reason ? { reason } : {}) };
  }
  const accountMoney = (item, at) => sourceFresh(at) && gateway?.apiSessionReady && item?.currency === "EUR" && typeof item.value === "string"
    && item.value.length <= 32 && /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]{1,8})?$/.test(item.value)
    ? { amount: item.value, currency: item.currency } : null;
  const equity = accountMoney(observation.equity, sourceAt("equity"));
  const cash = accountMoney(observation.cash, sourceAt("cash"));
  const oldest = times => times.filter(Boolean).sort()[0];
  // One account observation field in rev 9: use the oldest emitted money source.
  const accountAt = oldest([equity && sourceAt("equity"), cash && sourceAt("cash")])
    || oldest([sourceAt("equity"), sourceAt("cash")]) || bookAt || generatedAt;
  const positionsAt = sourceAt("positions");
  const positionsFresh = sourceFresh(positionsAt);
  const fields = ["quantity", "mark", "marketValue", "dayPnl", "openPnl"];
  const row = (identity, reason) => ({ ...identity, ...Object.fromEntries(fields.map(f => [f, null])),
    reasons: { ...Object.fromEntries(fields.map(f => [f, reason])),
      ...(identity.scope !== "keep" && identity.desk === null ? { desk: "desk_unmapped" } : {}) } });
  const reported = observation.positions || [];
  const rows = reported.map(identity => row({ ...identity, ...(identity.scope === "keep" || !positionsFresh ? { desk: null } : {}) },
    positionsFresh ? "not_exact_yet" : "source_unavailable"));
  for (const symbol of ["SXR8", "TSLA"]) {
    if (!rows.some(item => item.symbol === symbol)) rows.push(row({ symbol, side: "long", desk: null, scope: "keep" }, "source_unavailable"));
  }
  const money = () => ({
    equity: null, dayPnl: null, openPnl: null, totalPnl: null,
    reasons: { equity: "not_exact_yet", dayPnl: "not_exact_yet", openPnl: "not_exact_yet", totalPnl: "not_exact_yet" },
  });
  const candidate = {
    schema: "inspr.joe.household.v2", seq, generatedAt, mode: "PAPER", currency: "EUR",
    source: { kind: "live-ib-api", label: "hsb0 joe-board-pusher (paper Gateway projection)" },
    safety: { halt: false, haltReason: null, ...(gateway ? { gateway } : {}) },
    desks: [["j", "J"], ["joe", "Joe"], ["joel", "Joel"]].map(([id, label]) => ({
      id, label, state: deskState(observation.deskActivity?.[id], generatedAt, receivedAt), action: DESK_ACTION, money: money(),
    })),
    totals: money(),
    brokerAccount: { scope: "paper-account-including-keep", observedAt: accountAt, equity, cash,
      ...(!equity ? { reason: "source_unavailable" } : {}), ...(!cash ? { reasons: { cash: "source_unavailable" } } : {}) },
    positions: { source: "live-ib-api", observedAt: positionsAt || bookAt || generatedAt, rows,
      ...(!positionsFresh ? { reason: "source_unavailable" }
        : !gateway?.apiSessionReady ? { reason: gateway?.reason || "gateway_unconfirmed" } : {}) },
  };
  return revision === 10 ? applyExactValues(candidate, observation, generatedAt) : candidate;
}

export function acceptStage(acceptSnapshot, candidate, previous, receivedAt, floor, highWater = null) {
  if (candidate.seq <= floor) return { status: 422, reason: "sequence_replayed" };
  const accepted = acceptSnapshot("data", candidate, previous, receivedAt);
  if (accepted.status !== 200) return accepted;
  const checkedAt = candidate.safety.gateway?.checkedAt;
  // Match the board's post-acceptance gate, including unconfirmed old replies.
  if (canonical(checkedAt) && checkedAt <= candidate.generatedAt && highWater && checkedAt < highWater) {
    return { status: 422, reason: "clock_regressed" };
  }
  // If the local clock regressed between source and receipt, the board would
  // otherwise advance this check (age relative to generatedAt is nonnegative).
  // Skip the pair rather than create a watermark mismatch with the board.
  if (canonical(checkedAt) && checkedAt <= candidate.generatedAt && checkedAt > receivedAt) {
    return { status: 422, reason: "clock_ahead" };
  }
  return accepted;
}

// Synchronous durable operations run only inside the separately limited worker.
export class StageStore {
  constructor({ root = STATE_DIR, uid = 1000, gid = 1000, io = fs, boundary = () => {}, retainPairs = RETAIN_PAIRS, revision = contractRevision(), env = process.env, socketPath = SOCKET_PATH,
    onCheckpointDisabled = () => {
      if (process.send) process.send({ event: "checkpoint_disabled" });
      else console.log('{"event":"v2_stage_checkpoint_disabled","reason":"directory_unsafe"}');
    } } = {}) {
    if (!Number.isSafeInteger(retainPairs) || retainPairs < RETAIN_PAIRS || retainPairs > MAX_RETAIN_PAIRS) fail();
    if (![9, 10].includes(revision)) fail();
    Object.assign(this, { root, uid, gid, io, boundary, retainPairs, revision, socketPath, onCheckpointDisabled });
    // No default or legacy shared-directory fallback, including after rollback
    // of the host mount. The injected env object is only a test seam.
    this.checkpointRoot = env.JOE_V2_STAGE_CHECKPOINT_DIR || null;
    this.disabled = false;
  }
  check(name, kind, limit) {
    const target = name ? path.join(this.root, name) : this.root;
    const stat = this.io.lstatSync(target);
    if (stat.isSymbolicLink() || stat.uid !== this.uid || stat.gid !== this.gid
      || (stat.mode & 0o7777) !== (kind === "directory" ? 0o700 : 0o600)
      || (kind === "directory" ? !stat.isDirectory() : !stat.isFile() || stat.nlink !== 1)
      || (limit !== undefined && stat.size > limit)) fail();
    return target;
  }
  names(name = "", max = MAX_RETAIN_PAIRS + 8) {
    const dir = this.io.opendirSync(this.check(name, "directory"));
    const names = [];
    try {
      let entry;
      while ((entry = dir.readSync())) {
        names.push(entry.name);
        if (names.length > max) fail();
      }
    } finally { dir.closeSync(); }
    return names;
  }
  read(name, limit) {
    const target = this.check(name, "file", limit);
    const fd = this.io.openSync(target, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const opened = this.io.fstatSync(fd);
      if (!opened.isFile() || opened.nlink !== 1 || opened.uid !== this.uid || opened.gid !== this.gid || (opened.mode & 0o7777) !== 0o600 || opened.size > limit) fail();
      const buffer = Buffer.alloc(limit + 1);
      let used = 0;
      while (used < buffer.length) {
        const count = this.io.readSync(fd, buffer, used, buffer.length - used, null);
        if (!count) break;
        used += count;
      }
      if (used > limit) fail();
      return buffer.subarray(0, used);
    } finally { this.io.closeSync(fd); }
  }
  json(name, limit = 4096) { return JSON.parse(this.read(name, limit)); }
  syncDir(name, label) {
    const fd = this.io.openSync(this.check(name, "directory"), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try { this.io.fsyncSync(fd); this.boundary(label); } finally { this.io.closeSync(fd); }
  }
  write(name, bytes, label) {
    const fd = this.io.openSync(path.join(this.root, name), fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try {
      this.io.writeFileSync(fd, bytes);
      this.boundary(`${label}_write`);
      this.io.fsyncSync(fd);
      this.boundary(`${label}_fsync`);
    } finally { this.io.closeSync(fd); }
  }
  atomic(name, value, label) {
    const temp = `.${path.basename(name, ".json")}.tmp`;
    const bytes = Buffer.from(JSON.stringify(value));
    if (bytes.length > 4096) fail();
    this.write(temp, bytes, label);
    this.io.renameSync(path.join(this.root, temp), path.join(this.root, name));
    this.boundary(`${label}_rename`);
    this.syncDir("", `${label}_dir_fsync`);
  }
  async contracts() {
    verify(); // Before any contract imports (including JSON imports).
    const { validateContract } = await import("./contracts/index.mjs");
    const { acceptSnapshot } = await import("./contracts/accept.mjs");
    Object.assign(this, { validateContract, acceptSnapshot });
  }
  enroll() {
    // The operator explicitly recorded an empty v2 history for this host.
    if (this.names().some(name => name !== ".allocator.lock")) fail();
    this.check(".allocator.lock", "file", 0);
    this.atomic("sequence-state.json", {
      format: stateFormat, floor: 0, lastReservedSeq: 0,
      lastObservationId: null, lastGeneratedAt: null, lastGatewayCheckedAt: null,
    }, "enroll");
  }
  validateState(state) {
    if (!exactKeys(state, "format,floor,lastReservedSeq,lastObservationId,lastGeneratedAt,lastGatewayCheckedAt")
      || state.format !== stateFormat || state.floor !== 0
      || !Number.isSafeInteger(state.lastReservedSeq) || state.lastReservedSeq < state.floor
      || (state.lastGatewayCheckedAt !== null && (!canonical(state.lastGatewayCheckedAt) || state.lastGatewayCheckedAt > state.lastGeneratedAt))) fail();
    if (state.lastReservedSeq === 0) {
      if (state.lastObservationId !== null || state.lastGeneratedAt !== null || state.lastGatewayCheckedAt !== null) fail();
    } else if (!canonical(state.lastGeneratedAt) || (state.lastObservationId !== observationId(state.lastGeneratedAt) && !cycleId(state.lastObservationId)
      && !(state.lastGatewayCheckedAt === null && state.lastObservationId === JSON.stringify(["ops392.phase-a.v1", state.lastGeneratedAt])))) fail();
  }
  readPair(name, { withBytes = false } = {}) {
    if (!/^pair-[1-9]\d{0,15}$/.test(name)) fail();
    const names = this.names(name, 2).sort();
    if (JSON.stringify(names) !== JSON.stringify(["receipt.json", "snapshot.json"])) fail();
    const bytes = this.read(`${name}/snapshot.json`, 262144);
    const snapshot = JSON.parse(bytes);
    const receipt = this.json(`${name}/receipt.json`);
    const binding = receiptBinding(receipt);
    if (!(Object.keys(binding).length === 0 || validCycleReceipt(binding))
      || !exactKeys(receipt, "format,stagedReceivedAt,seq,generatedAt,generatedAdvancedAt,snapshotSha256,contractSetSha256"
        + (Object.keys(binding).length ? ",v1Sha256,v1Status,v1RepliedAt,observationId,v1PostStatus" : ""))
      || receipt.format !== pairFormat || !positiveSeq(snapshot.seq) || name !== `pair-${snapshot.seq}`
      || receipt.seq !== snapshot.seq || receipt.generatedAt !== snapshot.generatedAt
      || !canonical(receipt.stagedReceivedAt) || !canonical(receipt.generatedAdvancedAt)
      || receipt.generatedAdvancedAt > receipt.stagedReceivedAt
      || receipt.snapshotSha256 !== sha(bytes)
      || !(receipt.contractSetSha256 === CONTRACT_SHA || (receipt.contractSetSha256 === REV9_SHA && !snapshot.pnlSources))
      || !this.validateContract("data", snapshot, { stage: "ingress" }).ok
      || !this.validProjection(snapshot)
      || this.acceptSnapshot("data", snapshot, null, receipt.stagedReceivedAt).status !== 200) fail();
    return { value: { ...snapshot, receivedAt: receipt.stagedReceivedAt }, generatedAdvancedAt: receipt.generatedAdvancedAt,
      observationId: receipt.observationId || null, ...(withBytes ? { bytes } : {}) };
  }
  // Read-only publisher entry: current.json is the commit marker. Never scan
  // reservations, residue or pair directories for a newer uncommitted body.
  readCommittedPair() {
    let pointer;
    try { pointer = this.json("current.json"); }
    catch (error) { if (error.code === "ENOENT") return null; throw error; }
    if (!exactKeys(pointer, "format,pair") || pointer.format !== pointerFormat || typeof pointer.pair !== "string") fail();
    const pair = this.readPair(pointer.pair, { withBytes: true });
    return { bytes: pair.bytes, seq: pair.value.seq, generatedAt: pair.value.generatedAt };
  }
  validProjection(snapshot) {
    // Recovery verifies the closed switch-set shape without reclassifying old
    // checks against today's clock or inventing raw broker evidence.
    if (snapshot.pnlSources) return this.validExactProjection(snapshot);
    const expected = buildCandidate(snapshot.seq, snapshot.generatedAt);
    if (JSON.stringify(Object.keys(snapshot).sort()) !== JSON.stringify(Object.keys(expected).sort())) return false;
    for (const field of ["schema", "seq", "generatedAt", "mode", "currency", "source", "totals"]) {
      if (JSON.stringify(snapshot[field]) !== JSON.stringify(expected[field])) return false;
    }
    if (!Array.isArray(snapshot.desks) || snapshot.desks.length !== 3 || !snapshot.desks.every((desk, index) => {
      const template = expected.desks[index];
      return exactKeys(desk, "id,label,state,action,money") && desk.id === template.id && desk.label === template.label
        && ["working", "sit-out", "stuck"].includes(desk.state)
        && (desk.action === DESK_ACTION || (desk.state === "sit-out" && desk.action === "Valuation unavailable pending exact source validation."))
        && JSON.stringify(desk.money) === JSON.stringify(template.money);
    })) return false;
    if (!exactKeys(snapshot.safety, snapshot.safety.gateway ? "halt,haltReason,gateway" : "halt,haltReason")
      || snapshot.safety.halt !== false || snapshot.safety.haltReason !== null) return false;
    const account = snapshot.brokerAccount;
    const sourceFresh = at => {
      const age = Date.parse(snapshot.generatedAt) - Date.parse(at);
      return canonical(at) && age >= 0 && age <= ACTIVITY_FRESH_MS;
    };
    if (account.scope !== expected.brokerAccount.scope || !canonical(account.observedAt)
      || Object.hasOwn(account, "accountHint") || (!account.equity && account.reason !== "source_unavailable")
      || (!account.cash && account.reasons?.cash !== "source_unavailable")
      || (!sourceFresh(account.observedAt) && (account.equity !== null || account.cash !== null))) return false;
    const positions = snapshot.positions;
    return positions.source === "live-ib-api" && canonical(positions.observedAt)
      && (sourceFresh(positions.observedAt) || (positions.reason === "source_unavailable"
        && positions.rows.every(row => row.desk === null
          && ["quantity", "mark", "marketValue", "dayPnl", "openPnl"].every(field => row.reasons?.[field] === "source_unavailable"))))
      && ["SXR8", "TSLA"].every(symbol => positions.rows.some(row => row.symbol === symbol && row.scope === "keep" && row.desk === null))
      && positions.rows.every(row => exactKeys(row, "symbol,side,desk,scope,quantity,mark,marketValue,dayPnl,openPnl,reasons")
        && ["quantity", "mark", "marketValue", "dayPnl", "openPnl"].every(field => row[field] === null
          && ["not_exact_yet", "source_unavailable"].includes(row.reasons?.[field])));
  }
  validExactProjection(snapshot) {
    // Recovery checks persisted claims against their own source times. It never
    // refreshes them using the restart clock or substitutes new ledger inputs.
    if (typeof this.validateContract !== "function") return false;
    const template = buildCandidate(snapshot.seq, snapshot.generatedAt);
    if (!exactKeys(snapshot, Object.keys(template).concat("pnlSources").join(","))) return false;
    for (const field of ["schema", "mode", "currency", "source"]) {
      if (JSON.stringify(snapshot[field]) !== JSON.stringify(template[field])) return false;
    }
    if (!this.validateContract("data", snapshot, { stage: "ingress" }).ok) return false;
    if (snapshot.safety.halt !== false || snapshot.safety.haltReason !== null || Object.hasOwn(snapshot.safety, "executor")) return false;
    const fresh = (at, bound = ACTIVITY_FRESH_MS) => canonical(at)
      && Date.parse(snapshot.generatedAt) >= Date.parse(at) && Date.parse(snapshot.generatedAt) - Date.parse(at) <= bound;
    const validMoney = bag => exactKeys(bag, MONEY_FIELDS.concat(bag.reasons ? ["reasons"] : []).join(","))
      && MONEY_FIELDS.every(field => bag[field] === null ? Boolean(bag.reasons?.[field]) : !bag.reasons?.[field]
        && (!bag[field].fx || fresh(bag[field].fx.observedAt, 300000)));
    if (!validMoney(snapshot.totals) || snapshot.desks.length !== 3 || !snapshot.desks.every((desk, index) =>
      exactKeys(desk, "id,label,state,action,money,pnlSources") && desk.id === template.desks[index].id
      && desk.label === template.desks[index].label && desk.action === exactDeskAction(desk.money) && validMoney(desk.money)
      && ["day", "open"].every(kind => desk.pnlSources[kind].status !== "available" || fresh(desk.pnlSources[kind].observedAt, 300000)))) return false;
    const account = snapshot.brokerAccount;
    if (account.scope !== template.brokerAccount.scope || Object.hasOwn(account, "accountHint") || !canonical(account.observedAt)
      || (!fresh(account.observedAt) && (account.equity !== null || account.cash !== null))) return false;
    return snapshot.positions.source === "live-ib-api" && canonical(snapshot.positions.observedAt)
      && ["SXR8", "TSLA"].every(symbol => snapshot.positions.rows.some(row => row.symbol === symbol && row.scope === "keep" && row.desk === null))
      && snapshot.positions.rows.every(row => exactKeys(row, "symbol,side,desk,scope,quantity,mark,marketValue,dayPnl,openPnl,reasons"
        + (row.updatedAt === undefined ? "" : ",updatedAt")) && row.dayPnl === null
        && ["quantity", "mark", "marketValue", "openPnl"].every(field => row[field] === null
          ? Boolean(row.reasons[field]) : !row.reasons[field] && fresh(row.updatedAt, 300000) && fresh(snapshot.positions.observedAt)));
  }
  checkResidue(name, state) {
    if (name === ".sequence-state.tmp" || name === ".current.tmp") { this.read(name, 4096); return; }
    const match = /^(?:pair-|\.next-|\.retired-)([1-9]\d{0,15})$/.exec(name);
    if (!match || !positiveSeq(Number(match[1])) || Number(match[1]) > state.lastReservedSeq) fail();
    if (name.startsWith("pair-")) {
      this.readPair(name);
    } else {
      for (const child of this.names(name, 2)) {
        if (!["snapshot.json", "receipt.json"].includes(child)) fail();
        this.read(`${name}/${child}`, child === "snapshot.json" ? 262144 : 4096);
      }
    }
  }
  retire(name) {
    // Only entries completely recognized and checked under the lifetime lock.
    if (name.startsWith("pair-") || name.startsWith(".next-") || name.startsWith(".retired-")) {
      for (const child of this.names(name, 2)) this.io.unlinkSync(path.join(this.root, name, child));
      this.io.rmdirSync(path.join(this.root, name));
    } else this.io.unlinkSync(path.join(this.root, name));
  }
  checkpointStore() {
    if (!this.checkpointRoot) return null;
    try {
      if (typeof this.checkpointRoot !== "string" || !path.isAbsolute(this.checkpointRoot)) fail();
      const root = path.resolve(this.checkpointRoot);
      // The pusher sees the state parent rw, v2 ro, and the socket dir rw.
      // Reject ancestors too: placing the cache at /var/lib is not isolation.
      const shared = [path.dirname(STATE_DIR), path.dirname(this.root),
        path.dirname(SOCKET_PATH), path.dirname(this.socketPath),
        ...checkpointSharedReadOnlyDirs].map(dir => path.resolve(dir));
      const overlaps = (a, b) => a === b || a.startsWith(b + path.sep) || b.startsWith(a === path.sep ? a : a + path.sep);
      if (shared.some(dir => overlaps(root, dir))) fail();
      const cache = new StageStore({ root, uid: this.uid, gid: this.gid,
        io: this.io, boundary: this.boundary, env: {}, revision: this.revision });
      cache.check("", "directory"); // Real directory, stager uid/gid, exactly 0700.
      const realRoot = this.io.realpathSync(root);
      for (const dir of shared) {
        let realShared;
        try { realShared = this.io.realpathSync(dir); }
        catch (error) { if (error.code !== "ENOENT") throw error; realShared = dir; }
        if (overlaps(realRoot, realShared)) fail();
      }
      return cache;
    } catch {
      // Disable both reads and writes for this worker, with one value-free event.
      this.checkpointRoot = null;
      this.onCheckpointDisabled();
      return null;
    }
  }
  validateLogRow(row, state, previousSeq) {
    const binding = receiptBinding(row);
    if (!(Object.keys(binding).length === 0 || validCycleReceipt(binding))
      || !exactKeys(row, "format,seq,outcome,generatedAt,stagedReceivedAt,recordedAt,pairSha256"
        + (Object.keys(binding).length ? ",v1Sha256,v1Status,v1RepliedAt,observationId,v1PostStatus" : ""))
      || row.format !== logFormat || !positiveSeq(row.seq) || row.seq <= previousSeq || row.seq > state.lastReservedSeq
      || !["staged", "committed", "rejected"].includes(row.outcome)
      || ![row.generatedAt, row.stagedReceivedAt, row.recordedAt].every(canonical)
      || typeof row.pairSha256 !== "string" || !/^[0-9a-f]{64}$/.test(row.pairSha256)) fail();
    return binding;
  }
  readCheckpoint(fd, size, state, pairs) {
    try {
      const cache = this.checkpointStore();
      if (!cache) return null;
      cache.check("", "directory");
      const value = cache.json("receipts-checkpoint.json");
      if (!exactKeys(value, "format,offset,lastReceiptSeq,prefixSha256") || value.format !== checkpointFormat
        || !Number.isSafeInteger(value.offset) || value.offset < 0 || value.offset > size
        || !Number.isSafeInteger(value.lastReceiptSeq) || value.lastReceiptSeq < 0 || value.lastReceiptSeq > state.lastReservedSeq
        || typeof value.prefixSha256 !== "string" || !/^[0-9a-f]{64}$/.test(value.prefixSha256)
        || [...pairs.keys()].some(seq => seq <= value.lastReceiptSeq)) return null;
      // Check the actual boundary row as well as the hash: an inconsistent seq
      // must not let the cache hide retained pairs or weaken monotonicity.
      let boundaryRows = 0;
      if (value.offset === 0) {
        if (value.lastReceiptSeq !== 0) return null;
      } else {
        const bytes = Buffer.alloc(Math.min(value.offset, 1026));
        let used = 0;
        while (used < bytes.length) {
          const count = this.io.readSync(fd, bytes, used, bytes.length - used, value.offset - bytes.length + used);
          if (!count) return null;
          used += count;
        }
        if (bytes.at(-1) !== 10) return null;
        const start = bytes.lastIndexOf(10, bytes.length - 2) + 1;
        if ((start === 0 && value.offset > bytes.length) || bytes.length - start - 1 > 1024) return null;
        const row = JSON.parse(bytes.subarray(start, -1).toString("utf8"));
        this.validateLogRow(row, state, 0);
        if (row.seq !== value.lastReceiptSeq) return null;
        boundaryRows = 1;
      }
      const hash = createHash("sha256");
      const bytes = Buffer.alloc(65536);
      let offset = 0;
      while (offset < value.offset) {
        const count = this.io.readSync(fd, bytes, 0, Math.min(bytes.length, value.offset - offset), offset);
        if (!count) return null;
        hash.update(bytes.subarray(0, count)); offset += count;
      }
      if (hash.copy().digest("hex") !== value.prefixSha256) return null;
      return { ...value, hash, boundaryRows };
    } catch { return null; } // Rescan on any doubt about isolated validation progress.
  }
  rememberReceipt(row, bytes) {
    if (row.outcome !== "rejected") {
      this.receiptAnchors.push({ offset: this.receiptOffset, lastReceiptSeq: this.lastReceiptSeq,
        hash: this.receiptHash.copy() });
      // One extra pair covers the append-before-prune crash boundary.
      if (this.receiptAnchors.length > this.retainPairs + 1) this.receiptAnchors.shift();
    }
    this.receiptHash.update(bytes);
    this.receiptOffset += bytes.length;
    this.lastReceiptSeq = row.seq;
  }
  saveCheckpoint(anchor = this.receiptAnchors[0] || { offset: this.receiptOffset,
    lastReceiptSeq: this.lastReceiptSeq, hash: this.receiptHash }) {
    const cache = this.checkpointStore();
    if (!cache) return;
    try {
      cache.check("", "directory");
      // Refuse to replace unsafe files, including symlinks and hardlinks.
      for (const name of ["receipts-checkpoint.json", ".receipts-checkpoint.tmp"]) {
        try { cache.check(name, "file", 4096); }
        catch (error) { if (error.code === "ENOENT") continue; throw error; }
      }
      // A recognized, checked temp may remain after a killed atomic write.
      try { cache.retire(".receipts-checkpoint.tmp"); }
      catch (error) { if (error.code !== "ENOENT") throw error; }
      cache.atomic("receipts-checkpoint.json", { format: checkpointFormat, offset: anchor.offset,
        lastReceiptSeq: anchor.lastReceiptSeq, prefixSha256: anchor.hash.copy().digest("hex") }, "checkpoint");
    } catch {
      // Failure to persist this optional optimization leaves the log untouched.
      // The next start verifies the older checkpoint or scans the whole log.
    }
  }
  // Stream the prefix hash, then validate only the tail. Full scans retain the
  // same strict row/pair checks. Torn/invalid evidence is never truncated.
  openReceipts(state, pairs) {
    const name = "receipts.jsonl";
    if (!this.names().includes(name)) {
      this.write(name, Buffer.alloc(0), "log_create");
      this.syncDir("", "log_create_dir_fsync");
    }
    const fd = this.io.openSync(this.check(name, "file"), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const found = new Set();
    try {
      const stat = this.io.fstatSync(fd);
      if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== this.uid || stat.gid !== this.gid || (stat.mode & 0o7777) !== 0o600) fail();
      const checkpoint = this.readCheckpoint(fd, stat.size, state, pairs);
      this.receiptHash = checkpoint?.hash || createHash("sha256");
      this.receiptOffset = checkpoint?.offset || 0;
      this.lastReceiptSeq = checkpoint?.lastReceiptSeq || 0;
      this.receiptAnchors = [];
      this.recovery = { scanMode: checkpoint ? "tail" : "full", rowsScanned: checkpoint?.boundaryRows || 0 };
      const oldestPairSeq = Math.min(...pairs.keys());
      let nextCheckpointAt = this.receiptOffset + scanCheckpointBytes;
      const buffer = Buffer.alloc(65536);
      let pending = Buffer.alloc(0);
      let position = this.receiptOffset;
      let count;
      while ((count = this.io.readSync(fd, buffer, 0, buffer.length, position))) {
        position += count;
        pending = Buffer.concat([pending, buffer.subarray(0, count)]);
        let newline;
        while ((newline = pending.indexOf(10)) >= 0) {
          if (newline > 1024) fail();
          const bytes = pending.subarray(0, newline + 1);
          const row = JSON.parse(bytes.subarray(0, -1).toString("utf8"));
          this.recovery.rowsScanned++;
          const binding = this.validateLogRow(row, state, this.lastReceiptSeq);
          const pair = pairs.get(row.seq);
          if (pair) {
            if (row.outcome === "rejected" || row.pairSha256 !== pair.snapshotSha256
              || row.generatedAt !== pair.generatedAt || row.stagedReceivedAt !== pair.stagedReceivedAt
              || JSON.stringify(binding) !== JSON.stringify(receiptBinding(pair))) fail();
            found.add(row.seq);
          }
          this.rememberReceipt(row, bytes);
          // Save validated progress on full AND resumed scans. Never skip a
          // retained pair's receipt on the next start: it must be bound again.
          // Prefix bytes are always rehashed by readCheckpoint before reuse.
          if (this.checkpointRoot && this.receiptOffset >= nextCheckpointAt && row.seq < oldestPairSeq) {
            this.saveCheckpoint({ offset: this.receiptOffset,
              lastReceiptSeq: this.lastReceiptSeq, hash: this.receiptHash });
            nextCheckpointAt = this.receiptOffset + scanCheckpointBytes;
          }
          pending = pending.subarray(newline + 1);
        }
        if (pending.length > 1024) fail();
      }
      if (pending.length) fail();
    } finally { this.io.closeSync(fd); }
    return found;
  }
  appendReceipt(seq, outcome, generatedAt, stagedReceivedAt, pairSha256, recordedAt = new Date().toISOString(), binding = {}) {
    if (seq <= this.lastReceiptSeq) fail();
    const row = { format: logFormat, seq, outcome, generatedAt, stagedReceivedAt, recordedAt, pairSha256, ...binding };
    const bytes = Buffer.from(JSON.stringify(row) + "\n");
    const fd = this.io.openSync(this.check("receipts.jsonl", "file"), fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_NOFOLLOW);
    try {
      const stat = this.io.fstatSync(fd);
      if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== this.uid || stat.gid !== this.gid || (stat.mode & 0o7777) !== 0o600
        || stat.size !== this.receiptOffset) fail();
      this.io.writeFileSync(fd, bytes);
      this.boundary("log_append");
      this.io.fsyncSync(fd);
      this.boundary("log_fsync");
      this.rememberReceipt(row, bytes);
    } finally { this.io.closeSync(fd); }
    this.saveCheckpoint();
  }
  prunePairs(names = this.names()) {
    const pairs = names.filter(name => /^pair-[1-9]\d{0,15}$/.test(name))
      .sort((a, b) => Number(b.slice(5)) - Number(a.slice(5)));
    for (const name of pairs.slice(this.retainPairs)) {
      if (name === this.current) continue;
      const retired = `.retired-${name.slice(5)}`;
      // Recovery recognizes a partially removed tombstone, never a partial pair.
      this.io.renameSync(path.join(this.root, name), path.join(this.root, retired));
      this.syncDir("", "prune_rename_fsync");
      this.retire(retired);
      this.syncDir("", "retire_dir_fsync");
    }
  }
  async open() {
    await this.contracts();
    this.check(".allocator.lock", "file", 0);
    const state = this.json("sequence-state.json");
    this.validateState(state);
    const names = this.names();
    let current = null;
    let previous = null;
    if (names.includes("current.json")) {
      const pointer = this.json("current.json");
      if (!exactKeys(pointer, "format,pair") || pointer.format !== pointerFormat || typeof pointer.pair !== "string") fail();
      previous = this.readPair(pointer.pair);
      current = pointer.pair;
      if (previous.value.seq <= state.floor || previous.value.seq > state.lastReservedSeq
        || previous.value.generatedAt > state.lastGeneratedAt
        || (previous.value.safety.gateway?.checkedAt <= previous.value.generatedAt
          && previous.value.safety.gateway.checkedAt <= previous.value.receivedAt
          && (!state.lastGatewayCheckedAt || previous.value.safety.gateway.checkedAt > state.lastGatewayCheckedAt))
        || (previous.value.seq === state.lastReservedSeq && previous.value.generatedAt !== state.lastGeneratedAt)) fail();
      if (previous.value.seq === state.lastReservedSeq && cycleId(state.lastObservationId)
        && previous.observationId !== state.lastObservationId) fail();
    }
    const residue = names.filter(name => ![".allocator.lock", "sequence-state.json", "current.json", "receipts.jsonl"].includes(name));
    const pairs = new Map();
    // Validate every entry before cleanup or pruning. All old pairs stay checked.
    for (const name of residue) {
      this.checkResidue(name, state);
      if (name.startsWith("pair-")) {
        const receipt = this.json(`${name}/receipt.json`);
        if (receipt.generatedAt > state.lastGeneratedAt) fail();
        pairs.set(receipt.seq, receipt);
      }
    }
    const found = this.openReceipts(state, pairs);
    for (const [seq, receipt] of [...pairs].sort((a, b) => a[0] - b[0])) {
      if (!found.has(seq)) this.appendReceipt(seq, `pair-${seq}` === current ? "committed" : "staged",
        receipt.generatedAt, receipt.stagedReceivedAt, receipt.snapshotSha256, undefined, receiptBinding(receipt));
    }
    Object.assign(this, { state, previous, current });
    for (const name of residue.filter(name => !name.startsWith("pair-"))) this.retire(name);
    if (residue.some(name => !name.startsWith("pair-"))) this.syncDir("", "recovery_dir_fsync");
    this.prunePairs(names);
    this.saveCheckpoint();
    return this;
  }
  retainedSeqs() {
    return this.names().filter(name => /^pair-[1-9]\d{0,15}$/.test(name)).map(name => Number(name.slice(5))).sort((a, b) => a - b);
  }
  reserve(observation, receivedAt = new Date().toISOString()) {
    if (this.disabled) fail();
    if (typeof observation === "string") observation = { bookTs: observation };
    if (!normalizeBookTs(observation?.bookTs)) return { status: 422, reason: "source_time_invalid" };
    if (!canonical(receivedAt)) return { status: 422, reason: "source_time_invalid" };
    // Persist the observation-receipt instant before the body-store handshake.
    // The existing state format already contains this high water, including r15.
    const generatedAt = this.state.lastGeneratedAt && this.state.lastGeneratedAt > receivedAt
      ? this.state.lastGeneratedAt : receivedAt;
    if (Date.parse(generatedAt) - Date.parse(receivedAt) > 5000) return { status: 422, reason: "clock_ahead" };
    if (observation.v1Cycle?.observationId === this.state.lastObservationId) return { status: 422, reason: "cycle_replayed" };
    if (this.state.lastReservedSeq === Number.MAX_SAFE_INTEGER) { this.disabled = true; fail(); }
    try {
      const state = { ...this.state, lastReservedSeq: this.state.lastReservedSeq + 1,
        lastObservationId: observation.v1Cycle?.observationId || observationId(generatedAt), lastGeneratedAt: generatedAt };
      this.atomic("sequence-state.json", state, "reserve");
      this.state = state;
      return { status: 200, seq: state.lastReservedSeq };
    } catch { this.disabled = true; fail(); }
  }
  stage(observation, now = () => new Date().toISOString(), reservation = null, stored = false) {
    if (this.disabled) fail();
    if (typeof observation === "string") observation = { bookTs: observation };
    const stagedReceivedAt = now();
    reservation ||= this.reserve(observation, stagedReceivedAt);
    if (reservation.status !== 200) return reservation;
    try {
      const state = this.state;
      const generatedAt = state.lastGeneratedAt;
      if (reservation.seq !== state.lastReservedSeq
        || state.lastObservationId !== (observation.v1Cycle?.observationId || observationId(generatedAt))) fail();
      const binding = observation.v1Cycle ? cycleReceipt(observation.v1Cycle, stored) : {};
      if (!canonical(stagedReceivedAt)) fail();
      const candidate = buildCandidate(state.lastReservedSeq, generatedAt, observation, stagedReceivedAt, state.lastGatewayCheckedAt, this.revision);
      const bytes = Buffer.from(JSON.stringify(candidate));
      if (bytes.length > 262144) fail();
      const reject = (status, reason) => {
        this.appendReceipt(candidate.seq, "rejected", generatedAt, stagedReceivedAt, sha(bytes), undefined, binding);
        return { status, reason, seq: candidate.seq };
      };
      if (!this.validProjection(candidate) || !this.validateContract("data", candidate, { stage: "ingress" }).ok) return reject(422, "contract_invalid");
      freeze(candidate);
      const accepted = acceptStage(this.acceptSnapshot, candidate, this.previous, stagedReceivedAt, state.floor, state.lastGatewayCheckedAt);
      if (accepted.status !== 200) return reject(accepted.status, accepted.reason);
      const checkedAt = candidate.safety.gateway?.checkedAt;
      if (canonical(checkedAt) && checkedAt <= generatedAt && checkedAt <= stagedReceivedAt && checkedAt !== state.lastGatewayCheckedAt) {
        state.lastGatewayCheckedAt = checkedAt;
        this.atomic("sequence-state.json", state, "gateway");
      }
      const receipt = {
        format: pairFormat, stagedReceivedAt, seq: candidate.seq, generatedAt,
        generatedAdvancedAt: accepted.generatedAdvancedAt, snapshotSha256: sha(bytes),
        contractSetSha256: this.revision === 10 ? CONTRACT_SHA : REV9_SHA, ...binding,
      };
      const next = `.next-${candidate.seq}`;
      const pair = `pair-${candidate.seq}`;
      this.io.mkdirSync(path.join(this.root, next), { mode: 0o700 });
      this.boundary("pair_mkdir");
      this.write(`${next}/snapshot.json`, bytes, "snapshot");
      this.write(`${next}/receipt.json`, Buffer.from(JSON.stringify(receipt)), "receipt");
      this.syncDir(next, "pair_fsync");
      this.io.renameSync(path.join(this.root, next), path.join(this.root, pair));
      this.boundary("pair_rename");
      this.syncDir("", "pair_dir_fsync");
      this.atomic("current.json", { format: pointerFormat, pair }, "pointer");
      this.current = pair;
      this.previous = accepted;
      this.appendReceipt(candidate.seq, "committed", generatedAt, stagedReceivedAt, receipt.snapshotSha256, undefined, binding);
      this.prunePairs();
      return { status: 200, reason: null, seq: candidate.seq };
    } catch {
      this.disabled = true; // Even an uncertain rename/fsync must never reuse memory state.
      throw new Error("stage_storage_invalid");
    }
  }
}

export function prepareLock(root = STATE_DIR, uid = 1000, gid = 1000) {
  const store = new StageStore({ root, uid, gid });
  store.check("", "directory");
  const lock = path.join(root, ".allocator.lock");
  try {
    const fd = fs.openSync(lock, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    fs.closeSync(fd);
    store.syncDir("", "lock_dir_fsync");
  } catch (error) { if (error.code !== "EEXIST") throw error; }
  return store.check(".allocator.lock", "file", 0);
}

export function launchLocked({ root = STATE_DIR, args = [], uid = 1000, gid = 1000, env = process.env, spawnWorker = spawn } = {}) {
  const lock = prepareLock(root, uid, gid);
  return spawnWorker("flock", ["--no-fork", "--nonblock", lock, process.execPath, fileURLToPath(import.meta.url), "--lock-held", ...args], {
    stdio: ["ignore", "pipe", "pipe", "ipc"],
    env: { PATH: env.PATH, NODE_ENV: "production",
      ...(env.JOE_V2_STAGE_CHECKPOINT_DIR ? { JOE_V2_STAGE_CHECKPOINT_DIR: env.JOE_V2_STAGE_CHECKPOINT_DIR } : {}),
      ...(contractRevision() === 10 ? { JOE_V2_CONTRACT_REV: "10" } : {}) },
  });
}

export async function serveWorker({ store, socketPath = SOCKET_PATH, notify = message => process.send?.(message), createServer = net.createServer, setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
  // Only the lock-holding worker may retire a stale socket.
  const parent = fs.lstatSync(path.dirname(socketPath));
  if (!parent.isDirectory() || parent.isSymbolicLink() || (parent.mode & 0o7777) !== 0o700 || parent.uid !== store.uid || parent.gid !== store.gid) fail();
  try {
    const stale = fs.lstatSync(socketPath);
    if (!stale.isSocket() || stale.isSymbolicLink() || stale.uid !== store.uid || stale.gid !== store.gid || (stale.mode & 0o7777) !== 0o600) fail();
    fs.unlinkSync(socketPath);
  } catch (error) { if (error.code !== "ENOENT") throw error; }
  let active;
  const server = createServer(socket => {
    if (active) { socket.destroy(); return; }
    active = socket;
    let buffer = Buffer.alloc(MAX_FRAME_BYTES + 4);
    let used = 0;
    let length = null;
    let busy = false;
    let awaiting;
    let timer;
    const clear = () => { clearTimer(timer); timer = undefined; };
    const reset = () => { buffer = Buffer.alloc(MAX_FRAME_BYTES + 4); used = 0; length = null; };
    const finish = (observation, reservation, stored) => {
      clear();
      try {
        const result = store.stage(observation, undefined, reservation, stored);
        notify({ event: "job_done", outcome: result.status === 200 ? "committed" : "skipped", ...(positiveSeq(result.seq) ? { seq: result.seq } : {}) });
        if (observation.v1Cycle && stored !== true) notify({ event: "v1_unbound" });
      } catch {
        notify({ event: "disabled" });
        awaiting = undefined;
        socket.destroy(); server.close(); return;
      }
      awaiting = undefined; reset(); busy = false;
      if (!socket.destroyed) {
        if (observation.v1Cycle) socket.write(frame({ event: "v1_retained", retainedSeqs: store.retainedSeqs() }));
        socket.write(Buffer.from([0x01]));
      }
    };
    socket.on("error", () => socket.destroy());
    socket.on("close", () => {
      clear();
      if (awaiting) { const job = awaiting; awaiting = undefined; finish(job.observation, job.reservation, false); }
      if (active === socket) active = undefined;
    });
    socket.on("data", chunk => {
      if ((busy && !awaiting) || used + chunk.length > buffer.length) { socket.destroy(); return; }
      if (!timer) timer = setTimer(() => socket.destroy(), 5000);
      chunk.copy(buffer, used); used += chunk.length;
      if (length === null && used >= 4) {
        length = buffer.readUInt32BE();
        if (length < 1 || length > MAX_FRAME_BYTES) { socket.destroy(); return; }
      }
      if (length === null || used < length + 4) return;
      if (used !== length + 4) { socket.destroy(); return; }
      clear(); busy = true;
      if (!awaiting) notify({ event: "job_start" });
      let observation;
      try {
        const payload = buffer.subarray(4, used);
        const text = new TextDecoder("utf-8", { fatal: true }).decode(payload);
        observation = JSON.parse(text);
      } catch {
        if (awaiting) { const job = awaiting; finish(job.observation, job.reservation, false); }
        else notify({ event: "job_done", outcome: "skipped" });
        socket.destroy(); return;
      }
      if (awaiting) {
        const job = awaiting;
        if (!exactKeys(observation, "seq,observationId,stored") || typeof observation.stored !== "boolean"
          || observation.seq !== job.reservation.seq || observation.observationId !== job.observation.v1Cycle.observationId) {
          finish(job.observation, job.reservation, false); socket.destroy(); return;
        }
        finish(job.observation, job.reservation, observation.stored);
        return;
      }
      if (!validObservation(observation)) {
        socket.destroy(); notify({ event: "job_done", outcome: "skipped" }); return;
      }
      if (observation.v1Cycle) {
        let reservation;
        try { reservation = store.reserve(observation); }
        catch { notify({ event: "disabled" }); socket.destroy(); server.close(); return; }
        if (reservation.status === 200) {
          awaiting = { observation, reservation }; reset();
          timer = setTimer(() => {
            // The POST has already settled. Preserve a receipt even if its
            // optional local writer is stalled; late acks cannot bind it.
            finish(observation, reservation, false);
            socket.destroy();
          }, 1500);
          socket.write(frame({ event: "v1_store", seq: reservation.seq, observationId: observation.v1Cycle.observationId }));
          return;
        }
        notify({ event: "job_done", outcome: "skipped" });
        socket.write(frame({ event: "v1_retained", retainedSeqs: store.retainedSeqs() }));
        reset(); busy = false; socket.write(Buffer.from([0x01])); return;
      }
      finish(observation, null, false);
    });
    if (store.state) socket.write(frame({ event: "v1_retained", retainedSeqs: store.retainedSeqs() }));
    socket.write(Buffer.from([0x01]));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  fs.chmodSync(socketPath, 0o600);
  server.on("error", () => { notify({ event: "disabled" }); active?.destroy(); server.close(); });
  notify({ event: "ready", ...store.recovery });
  return server;
}

async function main() {
  process.umask(0o077);
  const args = process.argv.slice(2);
  if (args.some(arg => !["--enroll", "--lock-held"].includes(arg))) fail();
  if (!args.includes("--lock-held")) {
    const child = launchLocked({ args });
    child.stdout.resume(); child.stderr.resume();
    child.on("error", () => { console.log('{"event":"v2_stage_disabled","reason":"worker_unavailable"}'); process.exitCode = 1; });
    child.on("exit", code => { process.exitCode = code || 1; if (code === 0) process.exitCode = 0; });
    return;
  }
  const store = new StageStore();
  if (args.includes("--enroll")) {
    verify(); store.enroll();
    console.log('{"event":"v2_stage_enrolled"}');
  } else {
    await store.open();
    await serveWorker({ store });
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(() => {
    process.send?.({ event: "disabled" });
    console.log('{"event":"v2_stage_disabled","reason":"startup_invalid"}');
    process.exitCode = 1;
  });
}
