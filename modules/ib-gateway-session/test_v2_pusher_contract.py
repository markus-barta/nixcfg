"""HOSTD-77: actual v2 publisher lines satisfy the HOSTD-58 parser contract."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "modules" / "shared" / "fleet-alerts"))
SPEC = importlib.util.spec_from_file_location(
    "ib_gateway_session_v2_contract", Path(__file__).with_name("supervisor.py")
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load ib-gateway session supervisor")
sup = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = sup
SPEC.loader.exec_module(sup)


class V2PusherContract(unittest.TestCase):
    def test_timestamped_v2_post_carries_gateway_and_rejects_history(self):
        emitted = subprocess.run(
            ["node", "--input-type=module", "-e", """
import { createV2Publisher } from './v2-publisher.mjs';
import { buildCandidate } from './v2-stage-worker.mjs';
const at = '2026-10-22T04:24:00.000Z';
for (const gateway of [
  { apiSessionReady: true, checkedAt: at },
  { apiSessionReady: false, checkedAt: at, reason: 'clock_regressed' },
  undefined,
]) {
  const snapshot = buildCandidate(7, at, { apiReplyCheckedAt: at });
  snapshot.safety.gateway = gateway;
  const bytes = Buffer.from(JSON.stringify(snapshot));
  const publisher = createV2Publisher({
    reader: { contracts: async () => {}, readCommittedPair: () => ({ bytes, seq: 7, generatedAt: at }) },
    stateStore: { load: () => ({ lastPosted: null, pending: null, outcomes: [] }), save() {} },
    send: async () => ({ ok: true, status: 200, text: async () => JSON.stringify({ receivedAt: at }) }),
    now: () => at,
  });
  await publisher.push({ url: 'http://fixture.invalid/joe/inbox', token: 'synthetic-contract-token' });
}
"""],
            cwd=REPO / "hosts" / "hsb0" / "docker" / "joe-board-pusher",
            check=True, capture_output=True, text=True, timeout=30,
        )
        lines = emitted.stdout.splitlines()
        self.assertEqual(len(lines), 3)
        timestamp = "2026-10-22T04:24:01.123456Z"
        for line, gateway, last_error in zip(
            lines, (True, False, False), (None, "clock_regressed", "gateway_unknown")
        ):
            with self.subTest(gateway=gateway, last_error=last_error):
                event = json.loads(line)
                self.assertEqual(event["event"], "v2_post")
                self.assertEqual(set(event), {
                    "event", "status", "seq", "generatedAt", "receivedAt",
                    "recordedAt", "bodySha256", "outcome", "gateway",
                } | ({"lastError"} if last_error else set()))
                view = sup.parse_pusher_published_state(timestamp + " " + line)
                self.assertIsNotNone(view)
                self.assertEqual(view.source, "live_push_log")
                self.assertIs(view.gateway, gateway)
                self.assertEqual(view.last_error, last_error)
                self.assertEqual(view.generated_at_raw, event["generatedAt"])
                self.assertEqual(view.generated_at, sup.parse_iso_seconds(event["generatedAt"]))
                self.assertEqual(view.observed_at_raw, timestamp)
                self.assertEqual(view.observed_at, sup.parse_iso_seconds(timestamp))
                for marker in sup.HISTORY_MARKERS:
                    history = {**event, marker: {}}
                    self.assertIsNone(sup.parse_pusher_published_state(
                        timestamp + " " + json.dumps(history)
                    ))
        skipped = {"event": "v2_post_skipped", "reason": "committed_pair_or_post_state_unavailable"}
        self.assertIsNone(sup.parse_pusher_published_state(timestamp + " " + json.dumps(skipped)))


if __name__ == "__main__":
    unittest.main()
