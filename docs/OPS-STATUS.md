# Operations Status

Quick overview of infrastructure operations progress.

---

## Host Status

|     | Host          | OS    | Type    | Audited | Fixed | Last Action      |
| --- | ------------- | ----- | ------- | ------- | ----- | ---------------- |
| 🏠  | hsb0          | NixOS | Server  | ✅      | ✅    | 2025-12-08 SYSOP |
| 🏠  | hsb1          | NixOS | Server  | ✅      | ✅    | 2025-12-08 SYSOP |
| 🏠  | hsb8          | NixOS | Server  | ⏳      | ⏳    | 2025-12-08 SYSOP |
| 🌐  | csb0          | NixOS | Server  | ✅      | ✅    | 2025-12-08 SYSOP |
| 🌐  | csb1          | NixOS | Server  | ⏳      | ⏳    | -                |
| 🎮  | gpc0          | NixOS | Desktop | ⏳      | ⏳    | -                |
| 🖥️  | imac0         | macOS | Desktop | ⏳      | ⏳    | -                |
| 🖥️  | imac-mba-work | macOS | Desktop | ⏳      | ⏳    | -                |
| 💻  | mba-mbp-work  | macOS | Desktop | ⏳      | ⏳    | -                |

**Legend:** ✅ Done | ⏳ Pending | 🏠 Home | 🌐 Cloud | 🎮 Gaming | 🖥️ iMac | 💻 MacBook

---

## Progress Summary

| Metric            | Count |
| ----------------- | ----- |
| Total hosts       | 9     |
| Audited           | 4     |
| Fixed after audit | 4     |
| Pending audit     | 5     |

---

## Recent Actions

| Date       | Host | Role  | Action                                  |
| ---------- | ---- | ----- | --------------------------------------- |
| 2025-12-08 | hsb1 | SYSOP | Fixed 10 audit findings, added T04 test |
| 2025-12-08 | hsb0 | SYSOP | Fixed 13 audit findings, T15-T16 tests  |
| 2025-12-08 | hsb8 | SYSOP | Uzumaki deployed (tests pending)        |
| 2025-12-08 | csb0 | SYSOP | Added 7 test documentation files        |

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
