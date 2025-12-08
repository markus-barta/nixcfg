# Operations Status

Quick overview of infrastructure operations progress.

---

## Host Status

### NixOS

| Host    | Audited | Fixed | Last Action      |
| ------- | ------- | ----- | ---------------- |
| 🖥️ hsb0 | ✅      | ✅    | 2025-12-08 SYSOP |
| 🖥️ hsb1 | ✅      | ✅    | 2025-12-08 SYSOP |
| 🖥️ hsb8 | ⏳      | ⏳    | 2025-12-08 SYSOP |
| 🖥️ csb0 | ✅      | ✅    | 2025-12-08 SYSOP |
| 🖥️ csb1 | ⏳      | ⏳    | -                |
| 🎮 gpc0 | ⏳      | ⏳    | -                |

### macOS

| Host             | Audited | Fixed | Last Action |
| ---------------- | ------- | ----- | ----------- |
| 🍎 imac0         | ⏳      | ⏳    | -           |
| 🍎 imac-mba-work | ⏳      | ⏳    | -           |
| 🍎 mba-mbp-work  | ⏳      | ⏳    | -           |

**Legend:** ✅ Done | ⏳ Pending | 🖥️ Server | 🎮 Desktop | 🍎 macOS

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
