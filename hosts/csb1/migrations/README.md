# csb1 Migrations

One-time migration scripts. Each subdirectory represents a specific migration event.

## Structure

```
migrations/
└── 2025-11-hokage/     # Migration to external Hokage modules
    ├── 00-README.md
    ├── 01-pre-snapshot.sh
    ├── 02-post-verify.sh
    ├── ...
    └── snapshots/
```

## Migrations

| Migration         | Status      | Date       | Description                                  |
| ----------------- | ----------- | ---------- | -------------------------------------------- |
| `2025-11-hokage/` | ✅ Complete | 2025-11-29 | Migrate from local mixins to external Hokage |

## Philosophy

- **One-time**: These scripts are for specific events, not regular use
- **Ordered**: Scripts are numbered for execution order
- **Documented**: Each migration has its own README
- **Archived**: After completion, migrations remain for reference

## After Migration

Once a migration is complete:

1. Update status in this README
2. Keep scripts for historical reference
3. Snapshots can be cleaned up after verification period
