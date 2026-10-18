import { validateContract, REASONS } from './index.mjs';
import { validInstant } from './schema-validator.mjs';

// The HTTP boundary used by P3: an SSO redirect is never parsed as a snapshot.
// A failed refresh changes only the closed reason, never any receipt anchor.
export function acceptRead(kind, { status, redirected = false, payload, receivedAt, generatedAdvancedAt, gatewayProgress, reason }, previous = null) {
  const reject = reason => ({ ...previous, reason, value: previous?.value ?? null });
  if (redirected || [301, 302, 303, 307, 308, 401, 403].includes(status)) return reject('auth_required');
  if (reason && !REASONS.includes(reason)) return reject('contract_invalid');
  if (status !== 200) return reject(reason || (status === 404 ? 'route_not_found' :
    payload?.reason === 'feed_not_received' ? 'feed_not_received' : 'refresh_failed'));
  const checked = validateContract(kind, payload);
  if (!checked.ok) return reject(checked.reason);
  if (kind === 'fleet-config' && !validInstant(receivedAt)) return reject('contract_invalid');
  // A 200 response can carry the server's last good snapshot plus a rejection
  // header. Cold clients must retain that validated value and its old receipt.
  return { value: payload, reason: reason ?? null, ...(receivedAt ? { receivedAt } : {}),
    ...(generatedAdvancedAt ? { generatedAdvancedAt } : {}), ...(gatewayProgress ? { gatewayProgress } : {}) };
}
