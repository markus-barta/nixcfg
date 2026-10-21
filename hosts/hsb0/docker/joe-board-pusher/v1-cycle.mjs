import { createHash, randomUUID } from "node:crypto";

export const exactKeys = (value, keys) => value && typeof value === "object" && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify(keys.split(",").sort());
export const cycleId = value => typeof value === "string" && /^ops392\.v1-cycle\.[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
export const postStatus = value => (Number.isInteger(value) && value >= 100 && value <= 599)
  || ["post_failed", "reply_failed", "not_posted_v2_active"].includes(value);
const instant = value => typeof value === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(value)
  && Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
export const validCycle = value => exactKeys(value, "v1Sha256,v1Status,v1RepliedAt,observationId")
  && typeof value.v1Sha256 === "string" && /^[0-9a-f]{64}$/.test(value.v1Sha256)
  && postStatus(value.v1Status) && instant(value.v1RepliedAt) && cycleId(value.observationId);
export function cycleReceipt(cycle, stored) {
  return { ...cycle, v1PostStatus: cycle.v1Status, v1Status: stored ? cycle.v1Status : "v1_unbound" };
}
export const validCycleReceipt = value => exactKeys(value, "v1Sha256,v1Status,v1RepliedAt,observationId,v1PostStatus")
  && validCycle({ v1Sha256: value.v1Sha256, v1Status: value.v1PostStatus,
    v1RepliedAt: value.v1RepliedAt, observationId: value.observationId })
  && (value.v1Status === "v1_unbound" || value.v1Status === value.v1PostStatus);
export const receiptBinding = value => Object.fromEntries(["v1Sha256", "v1Status", "v1RepliedAt", "observationId", "v1PostStatus"]
  .filter(key => Object.hasOwn(value, key)).map(key => [key, value[key]]));
export const frame = value => {
  const bytes = Buffer.from(JSON.stringify(value));
  const out = Buffer.allocUnsafe(bytes.length + 4);
  out.writeUInt32BE(bytes.length); bytes.copy(out, 4);
  return out;
};

// Hash the same string passed to fetch. No filesystem work precedes the POST.
export function startCycle(body) {
  const v1Sha256 = createHash("sha256").update(body).digest("hex");
  const observationId = `ops392.v1-cycle.${randomUUID()}`;
  return (v1Status, v1RepliedAt = new Date().toISOString()) => ({ v1Sha256, v1Status, v1RepliedAt, observationId });
}
