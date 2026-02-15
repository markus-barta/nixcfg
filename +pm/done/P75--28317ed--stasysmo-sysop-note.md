# P7500: StaSysMo - Sticky SYSOP_NOTE

Add a persistent red warning/note to the prompt when `~/SYSOP_NOTE` exists.

## Requirements

- [ ] Read `~/SYSOP_NOTE` (first line, trimmed).
- [ ] If non-empty:
  - [ ] Prepend `!` in `COLOR_CRITICAL` (Red).
  - [ ] If terminal width permits, also show the full note text.
  - [ ] If terminal is narrow, keep ONLY the `!`.
- [ ] The `!` should never be truncated as long as StaSysMo is visible.

## Technical Details

- Modify `modules/uzumaki/stasysmo/reader.sh`.
- Use `COLOR_CRITICAL` for the indicator and text.
- Integrated into the `main` logic of the reader script.
