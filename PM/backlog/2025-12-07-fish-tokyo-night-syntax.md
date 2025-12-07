# 2025-12-07 - Fish Syntax Highlighting: Tokyo Night Theme

## Status: BACKLOG (Low Priority)

## Summary

Configure Fish shell syntax highlighting to use Tokyo Night colors, matching our theme system (Starship, Zellij, Eza, Helix all use Tokyo Night).

## Current State

Fish syntax highlighting currently uses catppuccin colors (from hokage). This is the last remaining catppuccin artifact after our Tokyo Night theme migration.

## Acceptance Criteria

- [ ] Research Fish syntax highlighting color options
- [ ] Define Tokyo Night color values for Fish
- [ ] Add Fish color configuration to uzumaki module
- [ ] Test on both NixOS and macOS hosts
- [ ] Visual verification that colors match the rest of the theme

## Implementation Options

### Option A: Fish set_color variables

```nix
# In programs.fish.interactiveShellInit or similar
programs.fish.interactiveShellInit = ''
  # Tokyo Night color scheme for Fish syntax highlighting
  set -U fish_color_normal c0caf5        # Normal text
  set -U fish_color_command 7aa2f7       # Commands
  set -U fish_color_keyword bb9af7       # Keywords
  set -U fish_color_quote 9ece6a         # Quoted strings
  set -U fish_color_redirection c0caf5   # Redirections
  set -U fish_color_end f7768e           # End of command
  set -U fish_color_error f7768e         # Errors
  set -U fish_color_param 9ece6a         # Parameters
  set -U fish_color_comment 565f89       # Comments
  set -U fish_color_selection --background=283457
  set -U fish_color_search_match --background=283457
  set -U fish_color_operator 89ddff      # Operators
  set -U fish_color_escape bb9af7        # Escape sequences
  set -U fish_color_autosuggestion 565f89
'';
```

### Option B: Use existing Tokyo Night fish theme

Check if there's a Tokyo Night fish theme package or community config.

## Tokyo Night Color Reference

| Color     | Hex       | Usage                    |
| --------- | --------- | ------------------------ |
| fg        | `#c0caf5` | Normal text              |
| blue      | `#7aa2f7` | Commands, functions      |
| purple    | `#bb9af7` | Keywords, escape         |
| green     | `#9ece6a` | Strings, params          |
| red       | `#f7768e` | Errors, end              |
| cyan      | `#89ddff` | Operators                |
| comment   | `#565f89` | Comments, autosuggestion |
| selection | `#283457` | Selection background     |

## Notes

- Related to: `2025-12-01-catppuccin-follows-cleanup.md`
- Should be added to `modules/uzumaki/fish/` or theme system
- Consider making it configurable per-host (some may prefer catppuccin)
