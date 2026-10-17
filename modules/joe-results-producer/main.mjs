import { constants, openSync, fstatSync, readFileSync, closeSync } from 'node:fs';
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

async function main() {
  verifyContracts();
  const options = readJson(process.argv[2]);
  if (options.mode !== 'paper') throw new Error('paper_only');
  const health = executorHealthUrl(options.executorHealth);
  if (options.stateDir !== '/var/lib/joe-results-producer' || options.capturePath !== '/var/lib/paper-desk-executor/results-input.jsonl') throw new Error('invalid_state_path');
  const producer = openProducer('/var/lib/joe-results-producer/results.jsonl', { keepSymbols: options.keepSymbols });
  const transport = httpTransport(options.endpoint, {
    origin: process.env.JOE_RESULTS_INGRESS_ORIGIN,
    keepSymbols: options.keepSymbols,
    headers: credentialHeaders(process.env.CREDENTIALS_DIRECTORY),
  });
  const runner = createRunner({ producer, transport,
    readSource: () => '/var/lib/paper-desk-executor/results-input.jsonl',
    readHealth: async () => {
      const response = await fetch(health, { redirect: 'error', signal: AbortSignal.timeout(3000) });
      if (!response.ok) { await response.body?.cancel(); throw new Error('executor_unavailable'); }
      const text = await response.text();
      if (Buffer.byteLength(text) > 65536) throw new Error('executor_unavailable');
      return JSON.parse(text);
    },
  });
  let stopping = false;
  const stop = () => { stopping = true; };
  process.once('SIGTERM', stop); process.once('SIGINT', stop);
  try {
    while (!stopping) {
      try { await runner.tick(); }
      catch (error) { console.error(JSON.stringify(failureDiagnostic(error))); }
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
