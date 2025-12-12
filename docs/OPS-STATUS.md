# Operations Status

Quick overview of infrastructure operations progress.

---

## Host Status

| •   | Host          | OS    | Type    | Audited             | Fixed               | Comment                                        |
| --- | ------------- | ----- | ------- | ------------------- | ------------------- | ---------------------------------------------- |
| 🏠  | hsb0          | NixOS | Server  | ✅ 2025-12-10 16:47 | ✅ 2025-12-10 16:47 | 17/17 tests pass, fixed local/remote execution |
| 🏠  | hsb1          | NixOS | Server  | ✅ 2025-12-10 18:03 | ✅ 2025-12-10 18:03 | 5/5 tests pass, fixed local/remote execution   |
| 🏠  | hsb8          | NixOS | Server  | ⏳                  | ⏳                  | Uzumaki deployed, tests pending (SYSOP)        |
| 🌐  | csb0          | NixOS | Server  | ✅ 2025-12-08 13:00 | ✅ 2025-12-08 13:30 | Added 7 test docs (SYSOP)                      |
| 🌐  | csb1          | NixOS | Server  | ✅ 2025-12-08 18:30 | ✅ 2025-12-08 18:35 | Minor fixes: Features table, ip-marker (SYSOP) |
| 🎮  | gpc0          | NixOS | Desktop | ⏳                  | ⏳                  | -                                              |
| 🖥️  | imac0         | macOS | Desktop | ✅ 2025-12-08 18:43 | ✅ 2025-12-08 18:43 | All 13 tests pass, removed sourceenv (SYSOP)   |
| 🖥️  | mba-imac-work | macOS | Desktop | ⏳                  | ⏳                  | -                                              |
| 💻  | mba-mbp-work  | macOS | Desktop | ⏳                  | ⏳                  | -                                              |

**Legend:** 🏠 Home | 🌐 Cloud | 🎮 Gaming | 🖥️ iMac | 💻 MacBook | ⏳ Pending

---

## Progress Summary

| Metric            | Count |
| ----------------- | ----- |
| Total hosts       | 9     |
| Audited           | 6     |
| Fixed after audit | 6     |
| Pending audit     | 3     |

---

## Pending Work

See `+pm/backlog/` for detailed task tracking.

**High priority:**

- hsb8: Run test suite, verify reboot

**Medium priority:**

- hsb0: Complete runbook-secrets TODOs
- hsb1: Complete runbook-secrets TODOs (system is degraded - investigate)
- gpc0: Audit

---

## Role Reference

| Role    | Trigger                           | Defined In                  |
| ------- | --------------------------------- | --------------------------- |
| SYSOP   | Working on hosts/modules/infra    | `.cursor/rules/SYSOP.mdc`   |
| AUDITOR | Auditing compliance/security/docs | `.cursor/rules/AUDITOR.mdc` |
