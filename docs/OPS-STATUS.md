# Operations Status

Quick overview of infrastructure operations progress.

---

## Host Status

| •   | Host          | OS    | Type    | Audited             | Fixed               | Comment                                                 |
| --- | ------------- | ----- | ------- | ------------------- | ------------------- | ------------------------------------------------------- |
| 🏠  | hsb0          | NixOS | Server  | ✅ 2025-12-24 22:33 | ❌ DEGRADED         | Outage 2025-12-25, see incident report (SYSOP)          |
| 🏠  | hsb1          | NixOS | Server  | ✅ 2025-12-24 22:28 | ✅ 2025-12-24 23:35 | 5/5 tests pass, exposed Terrasse D28 to HomeKit (SYSOP) |
| 🏠  | hsb8          | NixOS | Server  | ✅ 2025-12-24 23:45 | ✅ 2025-12-24 23:45 | Consolidated docs, fixed tests (SYSOP)                  |
| 🌐  | csb0          | NixOS | Server  | ✅ 2025-12-08 13:00 | ✅ 2025-12-08 13:30 | Added 7 test docs (SYSOP)                               |
| 🌐  | csb1          | NixOS | Server  | ✅ 2025-12-08 18:30 | ✅ 2025-12-08 18:35 | Minor fixes: Features table, ip-marker (SYSOP)          |
| 🎮  | gpc0          | NixOS | Desktop | ✅ 2025-12-24 23:45 | ✅ 2025-12-24 23:45 | Fixed tests & theme override (SYSOP)                    |
| 🖥️  | imac0         | macOS | Desktop | ✅ 2025-12-08 18:43 | ✅ 2025-12-08 18:43 | All 13 tests pass, removed sourceenv (SYSOP)            |
| 🖥️  | mba-imac-work | macOS | Desktop | ✅ 2025-12-24 23:55 | ✅ 2025-12-24 23:55 | All 9 tests pass, remote switch requires UI (SYSOP)     |
| 💻  | mba-mbp-work  | macOS | Desktop | ✅ 2025-12-24 23:55 | ✅ 2025-12-24 23:55 | All 4 tests pass, fixed hostcolors/aliases (SYSOP)      |

**Legend:** 🏠 Home | 🌐 Cloud | 🎮 Gaming | 🖥️ iMac | 💻 MacBook | ⏳ Pending

---

## Progress Summary

| Metric            | Count |
| ----------------- | ----- |
| Total hosts       | 9     |
| Audited           | 9     |
| Fixed after audit | 9     |
| Pending audit     | 0     |

---

## Pending Work

See `+pm/backlog/` for detailed task tracking.

**High priority:**

- imac0: Investigate why `imacw` function is missing (currently unreachable)

**Medium priority:**

- hsb0: Complete runbook-secrets TODOs (ping Markus for plain text password)
- hsb1: Complete runbook-secrets TODOs (partially done, ping Markus for remaining)
- hsb8: Update runbook-secrets TODOs (ping Markus)

---

## Role Reference

| Role    | Trigger                           | Defined In                  |
| ------- | --------------------------------- | --------------------------- |
| SYSOP   | Working on hosts/modules/infra    | `.cursor/rules/SYSOP.mdc`   |
| AUDITOR | Auditing compliance/security/docs | `.cursor/rules/AUDITOR.mdc` |
