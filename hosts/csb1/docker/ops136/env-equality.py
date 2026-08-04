#!/usr/bin/env python3
"""OPS-136 — in-process env/cmd equality between LIVE and DRILL containers.

Proves that the candidate spec (agenix env_files + inline environment)
materializes byte-identical container environments to the running legacy
containers, WITHOUT any secret value ever being printed, logged, or written.

Both sides were materialized by the same compose parser (the drill uses the
rendered candidate file), so this compares compose-semantic reality, not a
reimplementation of dotenv rules.

Output: one "<service> <VAR>: PASS|FAIL" line per variable (values never
leave the process), a Cmd verdict per service, and a nonzero exit on any
FAIL. Run as root (docker socket).
"""

import json
import subprocess
import sys

PAIRS = [
    # (live container, drill container)
    ("zitadel", "ops136drill-zitadel-1"),
    ("zitadel-postgres", "ops136drill-zitadel-postgres-1"),
    ("inspr-auth", "ops136drill-inspr-auth-1"),
    ("inspr-www", "ops136drill-inspr-www-1"),
    ("paimos-www", "ops136drill-paimos-www-1"),
]

# Vars whose live/drill values legitimately differ (drill isolation), with a
# short reason. Everything else must match byte-for-byte.
EXPECTED_DIFF = {
    "zitadel-postgres": {
        "POSTGRES_USER": "drill bootstraps as postgres so the restore can CREATE ROLE zitadel",
        "POSTGRES_DB": "drill bootstraps as postgres",
        "POSTGRES_PASSWORD": "live value is init-only recovery material; candidate correctness is proven functionally by the zitadel clone authenticating against the RESTORED role",
    },
}


def inspect(name):
    out = subprocess.check_output(["docker", "inspect", name])
    return json.loads(out)[0]["Config"]


def envmap(cfg):
    m = {}
    for item in cfg.get("Env") or []:
        k, _, v = item.partition("=")
        m[k] = v
    return m


def main():
    failures = 0
    for live_name, drill_name in PAIRS:
        live, drill = inspect(live_name), inspect(drill_name)
        le, de = envmap(live), envmap(drill)
        expected = EXPECTED_DIFF.get(live_name, {})

        # --- masterkey special case: live passes it on the command line,
        # candidate reads ZITADEL_MASTERKEY from env. Cross-check in-process.
        if live_name == "zitadel":
            lcmd = live.get("Cmd") or []
            live_mk = None
            for i, tok in enumerate(lcmd):
                if tok == "--masterkey" and i + 1 < len(lcmd):
                    live_mk = lcmd[i + 1]
                elif tok.startswith("--masterkey="):
                    live_mk = tok.split("=", 1)[1]
            drill_mk = de.get("ZITADEL_MASTERKEY")
            ok = live_mk is not None and drill_mk == live_mk
            print(f"zitadel MASTERKEY(cmd→env): {'PASS' if ok else 'FAIL'}")
            failures += 0 if ok else 1
            # Candidate cmd must be the P0-recorded form.
            want = ["start-from-init", "--masterkeyFromEnv", "--tlsMode", "external"]
            ok = (drill.get("Cmd") or []) == want
            print(f"zitadel CMD: {'PASS' if ok else 'FAIL'}")
            failures += 0 if ok else 1
        else:
            ok = (live.get("Cmd") or []) == (drill.get("Cmd") or []) and (
                live.get("Entrypoint") or []
            ) == (drill.get("Entrypoint") or [])
            print(f"{live_name} CMD+ENTRYPOINT: {'PASS' if ok else 'FAIL'}")
            failures += 0 if ok else 1

        # --- env: every live var must exist in drill with identical bytes.
        for k in sorted(le):
            if k in expected:
                print(f"{live_name} {k}: SKIP (expected-diff: {expected[k]})")
                continue
            ok = de.get(k) == le[k]
            print(f"{live_name} {k}: {'PASS' if ok else 'FAIL'}")
            failures += 0 if ok else 1
        # --- extras in drill: only the documented masterkey move is allowed.
        allowed_extra = {"zitadel": {"ZITADEL_MASTERKEY"}}.get(live_name, set())
        for k in sorted(set(de) - set(le)):
            if k in allowed_extra or k in expected:
                continue
            print(f"{live_name} {k}: FAIL (unexpected extra var in candidate)")
            failures += 1

    print(f"RESULT: {'PASS' if failures == 0 else f'FAIL ({failures})'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
