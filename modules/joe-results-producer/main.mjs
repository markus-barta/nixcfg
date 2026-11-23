import { constants, openSync, fstatSync, readFileSync, closeSync } from 'node:fs';
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { openProducer, createRunner } from './producer.mjs';
import { httpTransport, credentialHeaders, failureDiagnostic } from './transport.mjs';
import { verifyContracts } from './verify-contracts.mjs';

export function readJson(filename) {
  // CLI supplies only an immutable Nix settings file, never a state-relative path.
  if (typeof filename !== 'string' || !/^\/nix\/store\/[a-z0-9]{32}-joe-results-producer\.json$/.test(filename)) throw new Error('invalid_settings_path');
  const fd = openSync(filename, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = fstatSync(fd);
    if (!info.isFile() || info.size > 262144) throw new Error('source_not_authoritative');
    return JSON.parse(readFileSync(fd, 'utf8'));
  } finally { closeSync(fd); }
}

// Derived, value-free operator diagnostics; persistence must not stop Results.
export const EQUITY_CLOSE_DIAGNOSTICS_LIMIT = 50;
export function createEquityCloseDiagnosticsWriter(filename = '/var/lib/joe-results-producer/equity-close-diagnostics.json',
  { io = fs, diagnostic = event => console.error(JSON.stringify(event)) } = {}) {
  const directory = path.dirname(filename), prefix = `${path.basename(filename)}.`;
  try {
    for (const entry of io.readdirSync(directory, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.startsWith(prefix) || !entry.name.slice(prefix.length).endsWith('.tmp')) continue;
      try { io.unlinkSync(path.join(directory, entry.name)); } catch { /* Best-effort crash cleanup. */ }
    }
  } catch { /* Missing/unreadable diagnostics storage must not stop Results. */ }
  let previous, nextWarning = -Infinity;
  return diagnostics => {
    // null means no outcomes evaluation yet; an evaluated empty list clears old warnings.
    if (diagnostics === null) return;
    const reasonCounts = {};
    for (const { reason } of diagnostics) reasonCounts[reason] = (reasonCounts[reason] || 0) + 1;
    const integrity = reason => reason.startsWith('stream_') || /duplicate_outcome|conflict|invalid|day_not_closed/.test(reason);
    const entries = [...diagnostics].sort((a, b) => Number(integrity(b.reason)) - Number(integrity(a.reason))
      || (b.day || '').localeCompare(a.day || '')).slice(0, EQUITY_CLOSE_DIAGNOSTICS_LIMIT);
    const bytes = JSON.stringify({ diagnostics: entries, reasonCounts }) + '\n';
    if (bytes === previous) return;
    const temp = `${filename}.${randomUUID()}.tmp`;
    try {
      io.writeFileSync(temp, bytes, { flag: 'wx', mode: 0o600 });
      io.renameSync(temp, filename);
      previous = bytes;
    } catch {
      try { io.unlinkSync(temp); } catch { /* Preserve publication on storage errors. */ }
      if (Date.now() >= nextWarning) {
        nextWarning = Date.now() + 15 * 60_000;
        diagnostic({ event: 'desk_equity_close', reason: 'local_diagnostics_unavailable' });
      }
    }
  };
}

async function main() {
  verifyContracts();
  const options = readJson(process.argv[2]);
  if (options.mode !== 'paper') throw new Error('paper_only');
  const health = executorHealthUrl(options.executorHealth);
  if (options.stateDir !== '/var/lib/joe-results-producer' || options.capturePath !== '/var/lib/paper-desk-executor/results-input.jsonl') throw new Error('invalid_state_path');
  const producer = openProducer('/var/lib/joe-results-producer/results.jsonl', {
    keepSymbols: options.keepSymbols,
    equityClosePath: '/var/lib/joe-desk-equity-closes/outcomes.jsonl',
  });
  const transport = httpTransport(options.endpoint, {
    origin: process.env.JOE_RESULTS_INGRESS_ORIGIN,
    keepSymbols: options.keepSymbols,
    headers: credentialHeaders(process.env.CREDENTIALS_DIRECTORY),
  });
  const runner = createRunner({ producer, transport,
    readSource: () => '/var/lib/paper-desk-executor/results-input.jsonl',
    readHealth: () => readExecutorHealth(health),
  });
  const writeCloseDiagnostics = createEquityCloseDiagnosticsWriter();
  let stopping = false;
  const stop = () => { stopping = true; };
  process.once('SIGTERM', stop); process.once('SIGINT', stop);
  try {
    while (!stopping) {
      let attempted = true;
      try { attempted = await runner.tick(); }
      catch (error) { console.error(JSON.stringify(failureDiagnostic(error))); }
      finally { if (attempted) writeCloseDiagnostics(producer.equityCloseDiagnostics); }
      await new Promise(resolve => setTimeout(resolve, 500));
    }
  } finally { producer.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main().catch(() => {
  console.error(JSON.stringify({ status: 'producer_start_failed' })); process.exitCode = 1;
});

export function executorHealthUrl(value) {
  if (value !== 'http://127.0.0.1:8472/v1/health') throw new Error('executor_loopback_only');
  // Fixed loopback URL: no network destination is taken from settings/state.
  return new URL('http://127.0.0.1:8472/v1/health');
}

export async function readExecutorHealth(url, request = fetch) {
  const response = await request(url, { redirect: 'error', signal: AbortSignal.timeout(3000) });
  if (response.status === 503) {
    // The runner records unavailable diagnostics and sends validated Results.
    await response.body?.cancel().catch(() => {});
    return null;
  }
  if (!response.ok) { await response.body?.cancel(); throw new Error('executor_unavailable'); }
  const text = await response.text();
  if (Buffer.byteLength(text) > 65536) throw new Error('executor_unavailable');
  return JSON.parse(text);
}
