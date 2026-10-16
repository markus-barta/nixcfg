import { validateContract } from './contracts/index.mjs';
import { acceptSnapshot } from './contracts/accept.mjs';

export function endpointUrl(value) {
  const url = new URL(value);
  if (url.username || url.password || url.search || url.hash || (url.protocol !== 'https:' && !(url.protocol === 'http:' && url.hostname === '127.0.0.1'))) throw new Error('invalid_ingress_endpoint');
  return url;
}

export function httpTransport(endpoint, { fetchImpl = fetch, headers = () => ({}), keepSymbols = ['SXR8', 'TSLA'] } = {}) {
  const url = endpointUrl(endpoint);
  return {
    keepSymbols,
    async send(payload) {
      if (!validateContract('results', payload, { stage: 'ingress' }).ok) throw new Error('contract_invalid');
      const supplied = await headers();
      if (Object.keys(supplied).some(key => key.toLowerCase() === 'x-joe-received-at')) throw new Error('server_owned_header');
      const response = await fetchImpl(url, { method: 'POST', redirect: 'error', signal: AbortSignal.timeout(4000), headers: { ...supplied, 'content-type': 'application/json' }, body: JSON.stringify(payload) });
      // Do not log a response body, URL or credential. The ingress owns receipt.
      if (!response.ok) { await response.body?.cancel(); throw new Error('ingress_rejected'); }
      await response.body?.cancel();
    },
  };
}

// Local fixture ingress runs the EXACT pinned acceptance function and stamps
// its own clock. It is never selected by the production entry point.
export function fixtureIngress({ now = () => new Date().toISOString() } = {}) {
  let previous = null;
  return {
    keepSymbols: ['SXR8', 'TSLA'],
    async send(payload) {
      const accepted = acceptSnapshot('results', payload, previous, now());
      if (accepted.status !== 200) throw new Error(accepted.reason);
      previous = accepted;
      return { status: 200, headers: { 'X-Joe-Received-At': previous.value.receivedAt } };
    },
    get accepted() { return previous; },
  };
}
