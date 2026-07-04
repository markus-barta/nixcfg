#!/usr/bin/env bash
# ╭────────────────────────────────────────────────────────────────────────────╮
# │  Claude Code statusline · single-line transparent typographic · truecolor  │
# │                                                                            │
# │   session · repo · branch(±⇡⇣) · PR · ✳model · effort/thinking ·          │
# │   context battery+bar(compact-notch@80%) · €cost+burn · 5h/7d limits ·     │
# │   duration+diff · clock                                                    │
# │                                                                            │
# │  No backgrounds — accent-colored nerd-font glyphs + text on terminal bg,   │
# │  dim · separators (catppuccin-mocha accents).                              │
# │                                                                            │
# │  data: statusline stdin JSON · git (5s cache) · ECB EUR rate (12h cache)   │
# │  requires: jq, nerd font · responsive ≥80 cols, full ≥140                  │
# ╰────────────────────────────────────────────────────────────────────────────╯
export LC_ALL=C
JQ=/Users/markus/.nix-profile/bin/jq
[ -x "$JQ" ] || JQ=jq
NOW=${EPOCHSECONDS:-$(date +%s)}
COLS=${COLUMNS:-999} # unknown width → render everything (no flicker between refresh paths)

# ── palette · catppuccin mocha (truecolor r;g;b) ────────────────────────────
TEXT="205;214;244" SUBTX="166;173;200" OVERLAY="108;112;134"
LAVENDER="180;190;254" BLUE="137;180;250" SAPPHIRE="116;199;236"
SKY="137;220;235" TEAL="148;226;213" GREEN="166;227;161"
YELLOW="249;226;175" PEACH="250;179;135" RED="243;139;168"
MAUVE="203;166;247" PINK="245;194;231" CLAUDE="217;119;87" # anthropic terracotta

R="\033[0m"
fg() { printf '\033[38;2;%sm' "$1"; }

# transparent segment: accent-colored icon + text (text may embed own colors)
# seg <accent-rgb> <icon> <text>
seg() {
  printf '%b%b %b%b%b' "$(fg "$1")" "$2" "$(fg "$TEXT")" "$3" "$R"
}

# ── payload → vars (one jq pass, \u001f-joined so empties survive) ──────────
IFS=$'\x1f' read -r SESSION MODEL EFFORT THINK FAST CWD REPO_OWNER REPO_NAME \
  WORKTREE PR_NUM PR_STATE COST DUR_MS ADDED REMOVED CTX_PCT CTX_SIZE CTX_TOK \
  RL5_PCT RL5_RESET RL7_PCT VERSION <<EOF
$($JQ -r '[
  (.session_name // "claude"),
  (.model.display_name // "?"),
  (.effort.level // "-"),
  (.thinking.enabled // false),
  (.fast_mode // false),
  (.workspace.current_dir // .cwd // "?"),
  (.workspace.repo.owner // ""),
  (.workspace.repo.name // ""),
  (.workspace.git_worktree // ""),
  (.pr.number // ""),
  (.pr.review_state // ""),
  (.cost.total_cost_usd // 0),
  (.cost.total_duration_ms // 0),
  (.cost.total_lines_added // 0),
  (.cost.total_lines_removed // 0),
  (.context_window.used_percentage // 0),
  (.context_window.context_window_size // 200000),
  (.context_window.total_input_tokens // 0),
  (.rate_limits.five_hour.used_percentage // ""),
  (.rate_limits.five_hour.resets_at // ""),
  (.rate_limits.seven_day.used_percentage // ""),
  (.version // "")
] | map(tostring) | join("\u001f")')
EOF

# ── helpers ─────────────────────────────────────────────────────────────────
human_tok() { # 166279→166k · 1048576→1.0M
  local t=${1%.*}
  if ((t >= 1000000)); then
    printf '%d.%dM' $((t / 1000000)) $((t % 1000000 / 100000))
  elif ((t >= 1000)); then
    printf '%dk' $((t / 1000))
  else printf '%d' "$t"; fi
}
fmt_dur() { # ms → 1h04m / 12m / 45s
  local s=$((${1%.*} / 1000))
  if ((s >= 3600)); then
    printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif ((s >= 60)); then
    printf '%dm' $((s / 60))
  else printf '%ds' "$s"; fi
}
until_ts() { # epoch → 2h13m
  local d=$((${1%.*} - NOW))
  ((d < 0)) && d=0
  if ((d >= 3600)); then
    printf '%dh%02dm' $((d / 3600)) $((d % 3600 / 60))
  elif ((d >= 60)); then
    printf '%dm' $((d / 60))
  else printf '%ds' "$d"; fi
}
gauge_color() { # rate-limit style thresholds
  local p=${1%.*}
  if ((p >= 90)); then
    echo "$RED"
  elif ((p >= 75)); then
    echo "$PEACH"
  elif ((p >= 50)); then
    echo "$YELLOW"
  else echo "$GREEN"; fi
}
ctx_color() { # context thresholds calibrated to auto-compact ≈ 80%
  local p=${1%.*}
  if ((p >= 78)); then
    echo "$RED"
  elif ((p >= 65)); then
    echo "$PEACH"
  elif ((p >= 50)); then
    echo "$YELLOW"
  else echo "$GREEN"; fi
}
battery_icon() { # remaining% → tiered battery glyph
  local r=${1%.*}
  if ((r >= 95)); then
    echo "󰁹"
  elif ((r >= 85)); then
    echo "󰂂"
  elif ((r >= 75)); then
    echo "󰂁"
  elif ((r >= 65)); then
    echo "󰂀"
  elif ((r >= 55)); then
    echo "󰁿"
  elif ((r >= 45)); then
    echo "󰁾"
  elif ((r >= 35)); then
    echo "󰁽"
  elif ((r >= 25)); then
    echo "󰁼"
  elif ((r >= 15)); then
    echo "󰁻"
  elif ((r >= 5)); then
    echo "󰁺"
  else echo "󰂎"; fi
}
bar() { # bar <pct> <width> [notch-cell] → ▰▰▰▱▱ with optional compact-notch ┃
  local p=${1%.*} w=$2 notch=${3:--1} filled i out=""
  filled=$(((p * w + 50) / 100))
  ((filled > w)) && filled=$w
  local fill_c
  fill_c=$(if [ "$notch" -ge 0 ]; then ctx_color "$p"; else gauge_color "$p"; fi)
  for ((i = 0; i < w; i++)); do
    if ((i == notch)); then
      if ((filled > i)); then out+="$(fg "$RED")┃"; else out+="$(fg "$OVERLAY")┃"; fi
    elif ((i < filled)); then
      out+="$(fg "$fill_c")▰"
    else out+="$(fg "$OVERLAY")▱"; fi
  done
  printf '%b%b' "$out" "$(fg "$TEXT")"
}

# ── git (5s cache per cwd) ──────────────────────────────────────────────────
GIT_SEG=""
CACHE_DIR="${TMPDIR:-/tmp}/claude-sl-$UID"
mkdir -p "$CACHE_DIR" 2>/dev/null
CKEY="$CACHE_DIR/git-$(printf '%s' "$CWD" | tr '/ ' '__')"
if [ -f "$CKEY" ]; then
  IFS='|' read -r CTS BRANCH DIRTY AHEAD BEHIND <"$CKEY"
else CTS=0; fi
if ((NOW - ${CTS:-0} >= 5)); then
  BRANCH=$(git -C "$CWD" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null ||
    git -C "$CWD" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$BRANCH" ]; then
    DIRTY=$(git -C "$CWD" --no-optional-locks status --porcelain 2>/dev/null | head -100 | wc -l | tr -d ' ')
    AB=$(git -C "$CWD" --no-optional-locks rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
    BEHIND=${AB%%$'\t'*}
    AHEAD=${AB##*$'\t'}
    [ -z "$AB" ] && {
      AHEAD=""
      BEHIND=""
    }
  fi
  printf '%s|%s|%s|%s|%s' "$NOW" "$BRANCH" "$DIRTY" "$AHEAD" "$BEHIND" >"$CKEY"
fi
if [ -n "$BRANCH" ]; then
  GTXT="$BRANCH"
  ((${DIRTY:-0} > 0)) && GTXT+=" $(fg "$YELLOW")✚${DIRTY}$(fg "$TEXT")"
  [ -n "$AHEAD" ] && ((AHEAD > 0)) && GTXT+=" $(fg "$SKY")⇡${AHEAD}$(fg "$TEXT")"
  [ -n "$BEHIND" ] && ((BEHIND > 0)) && GTXT+=" $(fg "$PEACH")⇣${BEHIND}$(fg "$TEXT")"
  GIT_SEG=$(seg "$MAUVE" "" "$GTXT")
fi

# ── repo / dir ──────────────────────────────────────────────────────────────
if [ -n "$REPO_NAME" ]; then
  RTXT="$REPO_NAME"
  ((COLS >= 120)) && [ -n "$REPO_OWNER" ] && RTXT="$REPO_OWNER/$REPO_NAME"
  RICO=""
else
  RTXT="${CWD##*/}"
  RICO="󰉋"
fi
[ -n "$WORKTREE" ] && RTXT+=" $(fg "$SUBTX")󰘬 $WORKTREE$(fg "$TEXT")"
REPO_SEG=$(seg "$BLUE" "$RICO" "$RTXT")

# ── PR badge (color = review state) ─────────────────────────────────────────
PR_SEG=""
if [ -n "$PR_NUM" ]; then
  case "$PR_STATE" in
  approved) PC="$GREEN" ;; changes_requested) PC="$RED" ;;
  draft) PC="$OVERLAY" ;; *) PC="$YELLOW" ;;
  esac
  PR_SEG=$(seg "$PC" "" "$(fg "$PC")#$PR_NUM")
fi

# ── model (claude ✳) + effort/thinking ──────────────────────────────────────
MTXT="$MODEL"
[ "$FAST" = "true" ] && MTXT+=" $(fg "$YELLOW")󱐋"
MODEL_SEG=$(seg "$CLAUDE" "✳" "$MTXT")

EFFORT_SEG=""
if [ "$EFFORT" != "-" ]; then
  case "$EFFORT" in
  low) EC="$SKY" ;; medium) EC="$TEAL" ;; high) EC="$YELLOW" ;;
  xhigh) EC="$PEACH" ;; max) EC="$RED" ;; *) EC="$SUBTX" ;;
  esac
  ETXT="$(fg "$EC")$EFFORT"
  [ "$THINK" = "true" ] && ETXT+=" $(fg "$LAVENDER")󰧑"
  EFFORT_SEG=$(seg "$EC" "󰈸" "$ETXT")
fi

# ── context: battery icon + notched bar (┃ = auto-compact ≈80%) ─────────────
CTX_P=${CTX_PCT%.*}
CC=$(ctx_color "$CTX_P")
CTX_TXT="$(bar "$CTX_P" 10 8) $(fg "$CC")${CTX_P}%$(fg "$TEXT")"
((COLS >= 100)) && CTX_TXT+=" $(fg "$SUBTX")$(human_tok "$CTX_TOK")/$(human_tok "$CTX_SIZE")"
CTX_SEG=$(seg "$CC" "$(battery_icon $((100 - CTX_P)))" "$CTX_TXT")

# ── cost in € (ECB rate, 12h cache, async refresh — never blocks) ───────────
RATE_F=~/.claude/cache/usd_eur.rate
RATE=0.87
if [ -f "$RATE_F" ]; then
  RAGE=$((NOW - $(stat -f %m "$RATE_F" 2>/dev/null || echo 0)))
  RC=$(cat "$RATE_F" 2>/dev/null)
  [ -n "$RC" ] && RATE=$RC
else
  RAGE=999999
fi
if ((RAGE > 43200)); then
  (curl -s --max-time 4 'https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR' |
    $JQ -r '.rates.EUR // empty' >"$RATE_F.tmp" 2>/dev/null &&
    [ -s "$RATE_F.tmp" ] && mv "$RATE_F.tmp" "$RATE_F" &) 2>/dev/null
fi
read -r EUR RATE_H < <(awk -v c="$COST" -v r="$RATE" -v ms="$DUR_MS" \
  'BEGIN { printf "%.2f %.2f", c*r, (ms>60000 ? c*r/(ms/3600000) : 0) }')
CTXT="${EUR}"
((COLS >= 110)) && [ "$RATE_H" != "0.00" ] && CTXT+=" $(fg "$SUBTX")󱐋 ${RATE_H}/h"
COST_SEG=$(seg "$GREEN" "󰇈" "$CTXT")

# ── anthropic rate limits: 5h + 7d ──────────────────────────────────────────
RL_SEG=""
if [ -n "$RL5_PCT" ]; then
  RLC=$(gauge_color "$RL5_PCT")
  RLTXT="$(bar "$RL5_PCT" 5) $(fg "$RLC")${RL5_PCT%.*}%$(fg "$TEXT")"
  ((COLS >= 90)) && [ -n "$RL5_RESET" ] && RLTXT+=" $(fg "$SUBTX")󰦖 $(until_ts "$RL5_RESET")$(fg "$TEXT")"
  if ((COLS >= 100)) && [ -n "$RL7_PCT" ]; then
    RLTXT+=" $(fg "$SUBTX")7d$(fg "$TEXT") $(bar "$RL7_PCT" 5) $(fg "$(gauge_color "$RL7_PCT")")${RL7_PCT%.*}%"
  fi
  RL_SEG=$(seg "$RLC" "󰓅" "$RLTXT")
fi

# ── session: duration + diff ────────────────────────────────────────────────
STXT="$(fmt_dur "$DUR_MS")"
if ((COLS >= 100)); then
  STXT+=" $(fg "$GREEN") ${ADDED%.*} $(fg "$RED") ${REMOVED%.*}"
fi
SESS_SEG=$(seg "$SAPPHIRE" "󰔛" "$STXT")

# ── assemble: one line, dim · separators ────────────────────────────────────
HDR_SEG=$(seg "$PINK" "" "\033[1m${SESSION}\033[22m")
PARTS=("$HDR_SEG" "$REPO_SEG")
[ -n "$GIT_SEG" ] && PARTS+=("$GIT_SEG")
[ -n "$PR_SEG" ] && PARTS+=("$PR_SEG")
PARTS+=("$MODEL_SEG")
[ -n "$EFFORT_SEG" ] && PARTS+=("$EFFORT_SEG")
PARTS+=("$CTX_SEG" "$COST_SEG")
[ -n "$RL_SEG" ] && PARTS+=("$RL_SEG")
PARTS+=("$SESS_SEG")
if ((COLS >= 120)); then
  CLOCK=$(printf '%(%H:%M)T' -1 2>/dev/null)
  [ -z "$CLOCK" ] && CLOCK=$(date +%H:%M)
  TAIL="$(fg "$OVERLAY")󰅐 $CLOCK"
  ((COLS >= 140)) && [ -n "$VERSION" ] && TAIL+=" · v$VERSION"
  PARTS+=("$TAIL$R")
fi

SEP=" $(fg "$OVERLAY")·$R "
OUT="${PARTS[0]}"
for p in "${PARTS[@]:1}"; do OUT+="$SEP$p"; done
printf '%b\n' "$OUT"
