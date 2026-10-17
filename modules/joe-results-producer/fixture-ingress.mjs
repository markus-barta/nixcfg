// Synthetic test server only; deliberately absent from source.nix/runtime.
// Mirrors JoeDesk's /joe/inbox handler, with kind='results' and its limit.
import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { CONTRACTS } from './contracts/index.mjs';
import { fixtureIngress, IngressError, RESULTS_PATH } from './transport.mjs';

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    let size = 0, oversized = false;
    const chunks = [];
    req.on('data', chunk => {
      size += chunk.length;
      if (size > limit) {
        if (!oversized) {
          oversized = true; chunks.length = 0;
          reject(Object.assign(new Error('too_large'), { code: 'TOO_LARGE' }));
        }
        return; // drain without buffering or destroying the response socket
      }
      if (!oversized) chunks.push(Buffer.from(chunk));
    });
    req.on('end', () => { if (!oversized) resolve(Buffer.concat(chunks)); });
    req.on('error', reject);
    req.on('aborted', () => reject(new Error('contract_invalid')));
  });
}

export function createFixtureIngressServer({ token = 'synthetic-joed20-token', now = () => new Date().toISOString() } = {}) {
  const ingress = fixtureIngress({ now });
  const server = createServer(async (req, res) => {
    const reply = (status, body, headers = {}) => {
      res.writeHead(status, { 'content-type': 'application/json', ...headers });
      res.end(JSON.stringify(body));
    };
    if (req.url !== RESULTS_PATH) return reply(404, { reason: 'route_not_found' });
    if (req.method !== 'POST') return reply(405, { reason: 'route_not_found' });
    if (!token) return reply(503, { reason: 'auth_required' });
    const authorization = String(req.headers.authorization || '');
    const supplied = Buffer.from(authorization.slice(0, 7).toLowerCase() === 'bearer ' ? authorization.slice(7).trim() : '');
    const expected = Buffer.from(token);
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return reply(401, { reason: 'auth_required' });
    let raw;
    try {
      raw = await readBody(req, CONTRACTS.limits.results);
    } catch (error) { return reply(error.code === 'TOO_LARGE' ? 413 : 400, { reason: 'contract_invalid' }); }
    let payload;
    try { payload = JSON.parse(raw.toString('utf8')); }
    catch { return reply(400, { reason: 'contract_invalid' }); }
    try {
      const result = await ingress.send(payload);
      return reply(200, { ok: true }, result.headers);
    } catch (error) {
      if (error instanceof IngressError) return reply(422, { reason: error.reason, errors: error.errors.slice(0, 20) });
      return reply(400, { reason: 'contract_invalid' });
    }
  });
  return {
    server,
    get accepted() { return ingress.accepted; },
    get stale() { return !ingress.accepted || Date.parse(now()) - Date.parse(ingress.accepted.value.receivedAt) >= 60_000; },
  };
}
