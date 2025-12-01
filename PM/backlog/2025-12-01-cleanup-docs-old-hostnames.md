# 2025-12-01 - Cleanup: Old Hostname References in Documentation

## Description

Update documentation files that still reference old hostnames (miniserver24, miniserver99, msww87, mba-gaming-pc).

## Source

- Discovered during PM sweep

## Scope

Applies to: docs/ directory, TOC.md, and other documentation

## Findings

### docs/README.md

- References "miniserver24" (should be hsb1)
- References "miniserver99" (should be hsb0)
- References "overview.md" which doesn't exist (should be technical-overview.md)

### docs/technical-overview.md

- Old hostname references
- "Future" note about hokage refactoring (may be outdated)

### docs/how-it-works.md

- References old hostnames
- Mentions csb1 migration scheduled for "November 22, 2025" (check if complete)

### TOC.md

- References old hostnames:
  - miniserver99 → hsb0
  - miniserver24 → hsb1
  - msww87 → hsb8
  - mba-gaming-pc → gpc0
  - imac-mba-home → imac0

### pbek.md

- References "/home/omega" paths (historical, may be intentional)

## Acceptance Criteria

- [ ] Update docs/README.md with current hostnames
- [ ] Fix overview.md → technical-overview.md link
- [ ] Update docs/technical-overview.md
- [ ] Update docs/how-it-works.md
- [ ] Update TOC.md with new hostnames
- [ ] Search for any other old hostname references
- [ ] Verify all internal links work

## Notes

- Some references may be intentionally historical (e.g., in pbek.md)
- Migration docs in archive/ folders should keep old names for historical accuracy
- Active documentation should use new hostnames
