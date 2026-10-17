import { validInstant } from './schema-validator.mjs';

// Two 30-second check cadences, matching the candidate's freshness bound.
export const GATEWAY_CHECK_MAX_AGE_MS = 60000;

// Producer-relative check age plus elapsed time on the server's clock. Never
// subtract a producer timestamp from server now; skew must not confirm/expire it.
export function gatewayCheckAgeMs(gateway, generatedAt, elapsedMs = 0) {
  if (!validInstant(gateway?.checkedAt) || !validInstant(generatedAt)) return null;
  const initialAge = Date.parse(generatedAt) - Date.parse(gateway.checkedAt);
  return initialAge >= 0 && Number.isFinite(elapsedMs) && elapsedMs >= 0 ? initialAge + elapsedMs : null;
}

export function gatewayReason(gateway, generatedAt, elapsedMs = 0) {
  if (gateway?.apiSessionReady === false) return gateway.reason || 'gateway_unconfirmed';
  const age = gatewayCheckAgeMs(gateway, generatedAt, elapsedMs);
  return gateway?.apiSessionReady === true && age !== null &&
    age < GATEWAY_CHECK_MAX_AGE_MS ? null : 'gateway_unconfirmed';
}
