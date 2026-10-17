import { constants, openSync, closeSync, fstatSync, readFileSync, lstatSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { CONTRACTS } from './contracts/index.mjs';
import { acceptSnapshot } from './contracts/accept.mjs';
import { validateResults } from './results-validation.mjs';
import { viennaDay } from './contracts/vienna-date.mjs';

export const RESULTS_PATH = '/joe/inbox/results';
const REASONS = new Set(['contract_invalid', 'schema_unsupported', 'sequence_replayed', 'clock_ahead', 'clock_regressed', 'auth_required', 'too_large', 'ingress_unavailable', 'transport_failed']);
const RULES = new Set(['json', 'maxBytes', 'const', 'enum', 'type', 'minimum', 'maximum', 'minLength', 'maxLength', 'pattern', 'date', 'date-time', 'minItems', 'maxItems', 'uniqueItems', 'contains', 'required', 'additionalProperties', 'anyOf', 'serverOwned', 'clockAhead', 'clockRegressed', 'sequenceReplayed', 'uniqueTrade', 'keepExcluded', 'tradeTimeOrder', 'positive', 'positiveFxRate', 'EUR', 'fxCurrency', 'nonnegative', 'netAfterFees', 'dayDeskRequired', 'dayTradeCount', 'dayNetSum', 'dayFeeSum', 'partialReasonsRequired', 'partialCoverageRequired', 'canonicalOrder', 'unattributedReasonRequired']);
const SAFE_PATH = /^\$(?:\.(?:schema|seq|generatedAt|receivedAt|currency|timeZone|trackingStart|missingDays|days|trades|benchmark|reason|date|coverage|partialReasons|unattributedCount|desks|j|joe|joel|equityClose|realisedNet|fees|amount|id|desk|symbol|side|quantity|openedAt|closedAt|entryPrice|exitPrice|grossEur|feesEur|netEur|fx|base|quote|rate|source|observedAt|method)|\.\d{1,6}|\[\d{1,6}\])*$/;

// Treat the server's error text as untrusted. Diagnostics may contain only
// known protocol reasons/rules and paths made from schema-owned field names.
export class IngressError extends Error {
  constructor(status, reason, errors = []) {
    super(REASONS.has(reason) ? reason : 'ingress_rejected');
    this.status = status;
    this.reason = this.message;
    this.errors = (Array.isArray(errors) ? errors : []).slice(0, 20)
      .filter(error => SAFE_PATH.test(error?.path) && RULES.has(error?.rule))
      .map(({ path, rule }) => ({ path, rule }));
  }
}

function resultsRejection(status, rejected, payload) {
  const error = new IngressError(status, rejected.reason, rejected.errors);
  // Inspect the complete response, before diagnostic filtering/truncation can
  // hide another error. The pinned receipt-dependent rule itself proves the
  // named day is closed at the server; inbox rejects expose no receipt clock.
  const errors = rejected.errors;
  if (status === 422 && rejected.reason === 'contract_invalid' && Array.isArray(errors) && errors.length === 1
    && errors[0]?.rule === 'partialReasonsRequired') {
    const match = /^\$\.days\[(0|[1-9]\d*)\]\.partialReasons$/.exec(errors[0].path);
    const day = match && payload.days[Number(match[1])];
    error.midnightStraddle = !!day && day.date === viennaDay(payload.generatedAt)
      && day.coverage === 'partial' && !day.partialReasons?.length;
  }
  return error;
}

export function failureDiagnostic(error) {
  return error instanceof IngressError
    ? { status: 'ingress_rejected', httpStatus: error.status, reason: error.reason, errors: error.errors }
    : { status: 'source_not_authoritative' };
}

// Raw token is read only by the running service from systemd's private copy.
// No token, header, path, endpoint or response body is included in diagnostics.
export function credentialHeaders(directory, expectedDirectory = '/run/credentials/joe-results-producer.service') {
  return () => {
    let fd;
    try {
      // systemd sets this directory; env cannot select another tree or a symlink.
      if (typeof directory !== 'string' || directory !== expectedDirectory || !path.isAbsolute(directory)
        || directory.split(path.sep).includes('..') || lstatSync(directory).isSymbolicLink()
        || realpathSync(directory) !== path.join(realpathSync(path.dirname(expectedDirectory)), path.basename(expectedDirectory))) throw new Error();
      fd = openSync(path.join(directory, 'joe-board-push-token'), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      const info = fstatSync(fd);
      if (!info.isFile() || info.size < 1 || info.size > 4096) throw new Error();
      const token = readFileSync(fd, 'utf8').trim();
      if (!token || /\s|[^\x21-\x7e]/.test(token)) throw new Error();
      return { authorization: `Bearer ${token}` };
    } catch { throw new IngressError(401, 'auth_required'); }
    finally { if (fd !== undefined) closeSync(fd); }
  };
}

async function rejectionBody(response) {
  if (!response.body) return {};
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 16_384) return {};
      chunks.push(Buffer.from(value));
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8')) || {};
  } catch { return {}; }
  finally { await reader.cancel().catch(() => {}); }
}

export function endpointUrl(value, origin) {
  if (typeof origin !== 'string') throw new Error('invalid_ingress_endpoint');
  const pin = new URL(origin);
  if (pin.origin !== origin || pin.username || pin.password || pin.pathname !== '/' || pin.search || pin.hash
    || (pin.protocol !== 'https:' && !(pin.protocol === 'http:' && pin.hostname === '127.0.0.1'))) throw new Error('invalid_ingress_endpoint');
  const url = new URL(value);
  if (url.origin !== pin.origin) throw new Error('invalid_ingress_endpoint');
  if (url.pathname !== RESULTS_PATH || url.username || url.password || url.search || url.hash || (url.protocol !== 'https:' && !(url.protocol === 'http:' && url.hostname === '127.0.0.1'))) throw new Error('invalid_ingress_endpoint');
  // Origin comes from the Nix module's service environment, never a state file.
  return new URL(RESULTS_PATH, pin.origin);
}

export function httpTransport(endpoint, { origin, fetchImpl = fetch, headers = () => ({}), keepSymbols = ['SXR8', 'TSLA'] } = {}) {
  const url = endpointUrl(endpoint, origin);
  let lastGood = null;
  return {
    keepSymbols,
    async send(payload) {
      const body = JSON.stringify(payload);
      // Reserve the board's server-owned UTC millisecond timestamp as well as
      // the ingress bytes; a just-fitting ingress must fit when served too.
      const servedBytes = Buffer.byteLength(JSON.stringify({ ...payload, receivedAt: '2000-01-01T00:00:00.000Z' }));
      if (Buffer.byteLength(body) > CONTRACTS.limits.results || servedBytes > CONTRACTS.limits.results) throw new IngressError(413, 'too_large');
      const checked = validateResults(payload, { receivedAt: payload?.generatedAt });
      if (!checked.ok) throw new IngressError(422, checked.reason, checked.errors);
      const supplied = await headers();
      const requestHeaders = new Headers(supplied);
      if (requestHeaders.has('x-joe-received-at')) throw new Error('server_owned_header');
      if (!/^Bearer [\x21-\x7e]+$/.test(requestHeaders.get('authorization') || '')) throw new IngressError(401, 'auth_required');
      requestHeaders.set('content-type', 'application/json');
      let response;
      try {
        response = await fetchImpl(url, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(4000), headers: requestHeaders, body });
      } catch { throw new IngressError(0, 'transport_failed'); }
      if (response.status !== 200) {
        const rejected = await rejectionBody(response);
        const reason = ({ 400: 'contract_invalid', 401: 'auth_required', 413: 'too_large', 503: 'ingress_unavailable' })[response.status] || rejected.reason;
        if (response.status === 422) throw resultsRejection(response.status, { ...rejected, reason }, payload);
        throw new IngressError(response.status, reason);
      }
      await response.body?.cancel();
      lastGood = structuredClone(payload);
      return { status: 200 };
    },
    get lastGood() { return structuredClone(lastGood); },
  };
}

// Local fixture ingress runs the EXACT pinned acceptance function and stamps
// its own clock. It is never selected by the production entry point.
export function fixtureIngress({ now = () => new Date().toISOString() } = {}) {
  let previous = null;
  return {
    keepSymbols: ['SXR8', 'TSLA'],
    async send(payload) {
      const receivedAt = now();
      const checked = validateResults(payload, { receivedAt });
      if (!checked.ok) throw resultsRejection(422, checked, payload);
      const accepted = acceptSnapshot('results', payload, previous, receivedAt);
      if (accepted.status !== 200) throw new IngressError(422, accepted.reason, accepted.errors);
      previous = accepted;
      return { status: 200, headers: { 'X-Joe-Received-At': previous.value.receivedAt } };
    },
    get accepted() { return previous; },
  };
}
