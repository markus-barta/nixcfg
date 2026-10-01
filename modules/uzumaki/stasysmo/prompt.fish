# Loaded after Starship. Every profile is a complete powerline chain.
test "$TERM" != dumb; or return

function __stasysmo_keymap
    switch "$fish_key_bindings"
        case fish_hybrid_key_bindings fish_vi_key_bindings fish_helix_key_bindings
            printf '%s' "$fish_bind_mode"
        case '*'
            printf insert
    end
end

function __stasysmo_render --argument-names profile code duration job_count
    set -l keymap (__stasysmo_keymap)
    set -l pipeline "$code"
    set -q __stasysmo_pipeline; and set pipeline "$__stasysmo_pipeline"
    set -g __stasysmo_lines (command starship prompt --profile="$profile" --terminal-width=10000 --status="$code" --pipestatus="$pipeline" --keymap="$keymap" --cmd-duration="$duration" --jobs="$job_count" 2>/dev/null)
    or return 1
    test (count $__stasysmo_lines) = 3; or return 1
    string match -rq '^[1-9][0-9]{8,10} [0-9]{2}:[0-9]{2}:[0-9]{2}$' -- "$__stasysmo_lines[2]"
end

function __stasysmo_rail
    set -l previous ''
    for key in $argv
        set -l text ''
        set -l bg "$STASYSMO_DARKEST"
        switch "$key"
            case failure
                set_color --bold "$STASYSMO_ERROR"
                printf '✘ %s ' "$__stasysmo_code"
                set_color normal
                continue
            case clock
                set text " $__stasysmo_clock"
                set bg "$STASYSMO_DARKER"
            case duration
                set text "⏱ "(math -s1 "$__stasysmo_duration / 1000")"s"
                set bg "$STASYSMO_DARKER"
            case nix
                switch "$IN_NIX_SHELL"
                    case pure impure unknown
                        set text " $IN_NIX_SHELL"
                    case '*'
                        set text ' nix'
                end
            case sudo
                # The theme's sudo symbol is empty; do not spawn sudo to render it.
                continue
            case '*'
                set -l index (string replace metric '' -- "$key")
                set text "$__stasysmo_metrics[$index]"
        end
        test -n "$text"; or continue
        if test -z "$previous"
            set_color "$bg"
            printf ''
        else if test "$previous" != "$bg"
            set_color -b "$bg" "$previous"
            printf ''
        else
            printf '%s' "$STASYSMO_SPACER_METRICS"
        end
        set_color -b "$bg" "$STASYSMO_MUTED_LIGHT"
        printf ' %s ' "$text"
        set previous "$bg"
    end
    if test -n "$previous"
        set_color normal
        set_color "$previous"
        printf ''
        set_color normal
    end
    return 0
end

function __stasysmo_path --argument-names budget
    set -l path (string replace -ra '[\x00-\x1f\x7f-\x9f]' '?' -- "$PWD")
    if test "$PWD" = "$HOME"
        set path '~'
    else if string match -q -- "$HOME/*" "$PWD"
        set path '~/'(string sub -s (math (string length -- "$HOME") + 2) -- "$path")
    end
    if test (string length --visible -- "$path") -le "$budget"
        printf '%s' "$path"
        return
    end
    set -l components (string split / -- "$path" | string match -v '')
    # Locate a repo root with filesystem predicates; no git process in this path.
    set -l root "$PWD"
    set -l attempts 0
    while test "$root" != /; and not test -e "$root/.git"; and test "$attempts" -lt 256
        set attempts (math "$attempts + 1")
        set -l parent (string replace -r '/[^/]+$' '' -- "$root")
        test "$parent" != "$root"; or begin
            set root /
            break
        end
        set root "$parent"
        test -n "$root"; or set root /
    end
    test -e "$root/.git"; or set root /
    set -l repo (string replace -r '^.*/' '' -- "$root")
    while test (count $components) -gt 1
        # Remove complete leading components, never bytes from a directory name.
        set -e components[1]
        set -l candidate '…/'(string join / -- $components)
        if test (string length --visible -- "$candidate") -le "$budget"
            printf '%s' "$candidate"
            return
        end
        if test -n "$repo"; and test "$components[1]" = "$repo"
            break
        end
    end
    set -l last (string replace -r '^.*/' '' -- "$path")
    test -n "$last"; or set last /
    if test -n "$repo"; and test "$repo" != "$last"
        set -l candidate "…/$repo/$last"
        if test (string length --visible -- "$candidate") -le "$budget"
            printf '%s' "$candidate"
            return
        end
    end
    if test (string length --visible -- "$last") -le "$budget"
        printf '%s' "$last"
    else
        string shorten --max="$budget" --char='…' -- "$last"
    end
end

function __stasysmo_compose --argument-names code duration
    string match -rq '^[0-9]{1,3}$' -- "$code"; or return 1
    string match -rq '^[0-9]{1,12}$' -- "$duration"; or set duration 0
    string match -rq '^[1-9][0-9]{0,4}$' -- "$COLUMNS"; or return 1
    set -l width (math "$COLUMNS - 1")
    test "$width" -ge 4; or return 1
    set -l job_count (count (jobs -p))
    __stasysmo_render stasysmo_0 "$code" "$duration" "$job_count"; or return 1
    set -l time_fields (string split ' ' -- "$__stasysmo_lines[2]")
    set -g __stasysmo_clock "$time_fields[2]"
    set -g __stasysmo_code "$code"
    set -g __stasysmo_duration "$duration"
    __stasysmo_read "$time_fields[1]"; or return 1
    set -l keys
    test "$code" = 0; or set -a keys failure
    for i in 1 2 4 3
        set -q __stasysmo_metrics[$i]; and set -a keys metric$i
    end
    # A stale record has one marker, not four invented values.
    test "$duration" -lt 2000; or set -a keys duration
    set -a keys clock
    set -q IN_NIX_SHELL; and set -a keys nix
    set -l drops clock duration
    # Healthy metrics go first, then elevated, then critical, within drop order.
    for severity in 0 1 2
        for i in 4 3 2 1
            set -q __stasysmo_severity[$i]; and test "$__stasysmo_severity[$i]" = "$severity"; and set -a drops metric$i
        end
    end
    set -a drops nix sudo failure
    set -l root ''
    if test "$USER" = root
        set root (set_color --bold -b "$STASYSMO_ROOT_BG" "$STASYSMO_ROOT_FG"; printf ' ⚠ '; set_color normal)
    end
    set -l left "$root$__stasysmo_lines[1]"
    set -l right (__stasysmo_rail $keys | string collect)
    for drop in $drops
        test (math (string length --visible -- "$left") + (string length --visible -- "$right") + 1) -le "$width"; and break
        set -l index (contains -i -- "$drop" $keys)
        test -z "$index"; or set -e keys[$index]
        set right (__stasysmo_rail $keys | string collect)
    end
    set -l remote 0
    test -n "$SSH_TTY$SSH_CONNECTION"; and set remote 1
    for level in 1 2 3 4 5 6 7
        test (string length --visible -- "$left") -le "$width"; and break
        set -l profile stasysmo_$level
        test "$remote" = 1; and test "$level" -ge 3; and set profile stasysmo_ssh_$level
        __stasysmo_render "$profile" "$code" "$duration" "$job_count"; or return 1
        set left "$root$__stasysmo_lines[1]"
    end
    if test (string length --visible -- "$left") -gt "$width"
        set -l profile stasysmo_short
        test "$remote" = 1; and set profile stasysmo_ssh_short
        set -lx STASYSMO_DIRECTORY ''
        __stasysmo_render "$profile" "$code" "$duration" "$job_count"; or return 1
        # An exported empty value still renders the two interior spaces.
        set -l budget (math "$width - "(string length --visible -- "$root$__stasysmo_lines[1]"))
        if test "$budget" -lt 2; and test "$remote" != 1
            # At four/five columns the caps fit only without interior spaces.
            set -l directory (__stasysmo_path (math "$width - 2"))
            set -g __stasysmo_output (begin
                    set_color "$STASYSMO_DARKEST"
                    printf ''
                    set_color -b "$STASYSMO_DARKEST" "$STASYSMO_MUTED_LIGHT"
                    printf '%s' "$directory"
                    set_color normal
                    set_color "$STASYSMO_DARKEST"
                    printf ''
                    set_color normal
                    printf '\n%s' "$__stasysmo_lines[3]"
                end | string collect)
            return 0
        end
        if test "$budget" -lt 1
            # At extreme widths SSH identity gets its own bounded row.
            set -l identity (string shorten --max="$width" --char='…' -- "$USER@$hostname")
            set budget (math "$width - 4")
            set -g __stasysmo_output (printf '%s\n %s \n%s' "$identity" (__stasysmo_path "$budget") "$__stasysmo_lines[3]" | string collect)
            return 0
        end
        set STASYSMO_DIRECTORY (__stasysmo_path "$budget")
        __stasysmo_render "$profile" "$code" "$duration" "$job_count"; or return 1
        set left "$root$__stasysmo_lines[1]"
    end
    set -l pad (math "$width - "(string length --visible -- "$left")" - "(string length --visible -- "$right"))
    test "$pad" -ge 0; or return 1
    set -l padding (string repeat -n "$pad" ' ')
    set -g __stasysmo_output (printf '%s%s%s\e[0m\n%s' "$left" "$padding" "$right" "$__stasysmo_lines[3]" | string collect)
end

function __stasysmo_fallback --argument-names code
    set -l plain (command starship prompt --status="$code" --terminal-width="$COLUMNS" --keymap=(__stasysmo_keymap) 2>/dev/null)
    if test "$status" = 0; and test (count $plain) -gt 0
        printf '%s\n' $plain
    else
        set -l columns 80
        string match -rq '^[1-9][0-9]{0,4}$' -- "$COLUMNS"; and set columns "$COLUMNS"
        set -l path (string replace -ra '[\x00-\x1f\x7f-\x9f]' '?' -- "$PWD")
        printf '%s\n❯ ' (string shorten --max=(math "max(1, $columns - 1)") --char='…' -- "$path")
    end
end

# Capture the original for diagnostics; sourcing twice must not wrap our wrapper.
if functions -q fish_prompt; and not functions -q __stasysmo_original_prompt
    functions -c fish_prompt __stasysmo_original_prompt
end
function fish_right_prompt
end
function fish_prompt
    set -l result $status $pipestatus
    set -l code "$result[1]"
    if test "$TERM" = dumb
        if functions -q __stasysmo_original_prompt
            __stasysmo_original_prompt
        else
            printf '> '
        end
        return
    end
    set -g __stasysmo_pipeline (string join ' ' -- $result[2..-1])
    set -l duration "$CMD_DURATION"
    set -q STASYSMO_FISH_LAYOUT; and test "$STASYSMO_FISH_LAYOUT" = 0; and begin
        __stasysmo_fallback "$code"
        return
    end
    if __stasysmo_compose "$code" "$duration" 2>/dev/null
        printf '%s' "$__stasysmo_output"
    else
        __stasysmo_fallback "$code"
    end
end
