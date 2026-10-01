# Snapshot text is data. Validate the complete bounded record before any math.
# The clock comes from the compositor's existing Starship invocation.
function __stasysmo_read --argument-names now
    set -g __stasysmo_metrics
    set -g __stasysmo_severity
    set -l file "$STASYSMO_SNAPSHOT"
    test -f "$file"; and not test -L "$file"; or return 0
    set -l dir (string replace -r '/[^/]+$' '' -- "$file")
    test -d "$dir"; and not test -L "$dir"; or return 0
    set -l record
    # A FIFO is rejected above; huge files are bounded even without a newline.
    read --null --nchars 129 record <"$file" 2>/dev/null
    string match -rq '^v1 [1-9][0-9]{8,10} (100|[1-9]?[0-9]) (100|[1-9]?[0-9]) (100|[1-9]?[0-9]) (0|[1-9][0-9]{0,3})\.[0-9]{2} [1-9][0-9]{0,3}\n$' -- "$record"; or return 0
    string match -rq '^[1-9][0-9]{8,10}$' -- "$now"; or return 0
    set -l fields (string split ' ' -- (string trim -- "$record"))
    if test "$fields[2]" -gt "$now"; or test (math "$now - $fields[2]") -gt "$STASYSMO_STALE_SECONDS"
        set -g __stasysmo_metrics (printf '\e[38;5;%sm?' "$STASYSMO_COLOR_MUTED")
        set -g __stasysmo_severity 0
        return 0
    end
    set -l values $fields[3] $fields[4] $fields[5] $fields[6]
    set -l comparisons $fields[3] $fields[4] $fields[5] (math "$fields[6] / $fields[7]")
    for i in 1 2 3 4
        set -l severity 0
        set -l color "$STASYSMO_COLOR_MUTED"
        if test "$comparisons[$i]" -ge "$STASYSMO_CRITICAL[$i]"
            set severity 2
            set color "$STASYSMO_COLOR_CRITICAL"
        else if test "$comparisons[$i]" -ge "$STASYSMO_ELEVATED[$i]"
            set severity 1
            set color "$STASYSMO_COLOR_ELEVATED"
        end
        set -l suffix '%'
        test "$i" = 4; and set suffix ''
        set -ga __stasysmo_metrics (printf '\e[38;5;%sm%s%s%s%s' "$color" "$STASYSMO_ICONS[$i]" "$STASYSMO_SPACER_ICON_VALUE" "$values[$i]" "$suffix")
        set -ga __stasysmo_severity "$severity"
    end
end
