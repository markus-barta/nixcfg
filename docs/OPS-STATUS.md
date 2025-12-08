# Operations Status

Quick overview of infrastructure operations progress.

---

## Host Status

| •   | Host          | OS    | Type    | Audited             | Fixed               | Comment                                  |
| --- | ------------- | ----- | ------- | ------------------- | ------------------- | ---------------------------------------- |
| 🏠  | hsb0          | NixOS | Server  | ✅ 2025-12-08 14:30 | ✅ 2025-12-08 15:00 | Fixed 13 findings, T15-T16 tests (SYSOP) |
| 🏠  | hsb1          | NixOS | Server  | ✅ 2025-12-08 16:00 | ✅ 2025-12-08 17:00 | Fixed 10 findings, T04 test (SYSOP)      |
| 🏠  | hsb8          | NixOS | Server  | ⏳                  | ⏳                  | Uzumaki deployed, tests pending (SYSOP)  |
| 🌐  | csb0          | NixOS | Server  | ✅ 2025-12-08 13:00 | ✅ 2025-12-08 13:30 | Added 7 test docs (SYSOP)                |
| 🌐  | csb1          | NixOS | Server  | ⏳                  | ⏳                  | -                                        |
| 🎮  | gpc0          | NixOS | Desktop | ⏳                  | ⏳                  | -                                        |
| 🖥️  | imac0         | macOS | Desktop | ⏳                  | ⏳                  | -                                        |
| 🖥️  | imac-mba-work | macOS | Desktop | ⏳                  | ⏳                  | -                                        |
| 💻  | mba-mbp-work  | macOS | Desktop | ⏳                  | ⏳                  | -                                        |

**Legend:** 🏠 Home | 🌐 Cloud | 🎮 Gaming | 🖥️ iMac | 💻 MacBook | ⏳ Pending

---

## Progress Summary

| Metric            | Count |
| ----------------- | ----- |
| Total hosts       | 9     |
| Audited           | 4     |
| Fixed after audit | 4     |
| Pending audit     | 5     |

---

## Pending Work

See `.pm/backlog/` for detailed task tracking.

**High priority:**

- hsb8: Run test suite, verify reboot
- csb1: Full audit

**Medium priority:**

- hsb0: Complete runbook-secrets TODOs
- hsb1: Complete runbook-secrets TODOs
- gpc0: Audit

---

## Role Reference

| Role    | Trigger                           | Defined In                  |
| ------- | --------------------------------- | --------------------------- |
| SYSOP   | Working on hosts/modules/infra    | `.cursor/rules/SYSOP.mdc`   |
| AUDITOR | Auditing compliance/security/docs | `.cursor/rules/AUDITOR.mdc` |
