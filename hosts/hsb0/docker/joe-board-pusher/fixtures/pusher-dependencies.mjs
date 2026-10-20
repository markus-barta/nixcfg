// Synthetic boundary doubles for importing the complete, unmodified pusher.
// Only direct pusher dependencies are replaced; its real projection is loaded.
import { EventEmitter } from "node:events";

let state;
export function configure(next) { state = next; }
export default {
  readFileSync(file) {
    if (file !== "/run/secrets/joe-board-push-token") throw new Error("unexpected_file_read");
    state.reads++;
    return state.variant === "no-token" ? "" : "synthetic-test-token";
  },
  existsSync() { return false; },
  connect() {
    const socket = new EventEmitter();
    socket.setTimeout = () => {};
    socket.destroy = () => {};
    queueMicrotask(() => socket.emit("error", new Error("synthetic_no_live_port")));
    return socket;
  },
};
export const configuredPaperAccount = () => "DUFIXTURE";
export class IBApi {}
export const EventName = {};
export const EXECUTION_CAPTURE_SCHEMA = "synthetic";
export const CURRENT_DESK_OWNERSHIP_POLICY = {};
export const DESK_HISTORY_REVISION_METHOD = "synthetic";
export const FAMILY_BASELINE_PERIOD_START = "2026-01-01T00:00:00.000Z";
const noop = () => {};
export const reconcileExecutionCapture = noop;
export const captureFromFamilyLedgerFile = noop;
export const capturesFromOfficialWindowEvidence = noop;
export const normalizeEconomicCommission = noop;
export const normalizeEconomicExecution = noop;
export const calculateFamily = noop;
export const buildDeskDayBoundaryEvidence = noop;
export const calculateDeskEquities = noop;
export const deskOwnershipPolicyContract = noop;
export const createFileDayBaselineStore = noop;
export const createFileFamilyHistoryStore = noop;
export const projectBestAvailableHistory = noop;
export const readOfficialExecutionWindow = noop;
export const createFileFamilyStateStore = noop;
export const waitForExecutionCycle = async () => {};
export const contractsNeedingFlatNetMarks = noop;
export const createFlatNetMarkController = noop;
export const createNoOpFlatNetMarkController = () => ({ reset: noop });
export const createPortfolioRefreshController = () => ({ tick: noop });
export const createConnectionSupervisor = () => ({ start: noop, shutdown: noop });
export const createOfficialHistoryRefresher = () => ({ start: noop, stop: noop });
export const createStageHandoff = () => state.handoff;
export function createBrokerSessionAdapter() {
  const current = state;
  return { connected: current.variant !== "outage", snapshot: () => current.variant === "incomplete" ? null : current.book, retire: noop };
}
export function createFamilySessionAdapter() {
  const current = state;
  return { requestInFlight: false, project: () => current.failure, projectDeskEquities: () => current.failure, retire: noop };
}
export function createFamilyHistorySessionAdapter() {
  const current = state;
  return { project: () => current.failure, retire: noop };
}
export function createDeskDayPnlProducer() {
  const current = state;
  return { observe() { current.observes++; return current.failure; }, inspectState: () => ({ latest: current.retained }) };
}
