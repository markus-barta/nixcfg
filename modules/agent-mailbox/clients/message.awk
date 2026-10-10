# Decode the flat JSON object emitted by the mailbox, without jq/Python/Node.
# Run in LC_ALL=C so %c writes UTF-8 bytes identically on Linux and macOS.
# No message text becomes an awk program, shell command, or pathname.
function fail() { bad = 1; exit 1 }
function space() { while (substr(json, pos, 1) ~ /[ \t\r\n]/ && pos <= length(json)) pos++ }
function hex4(    s, i, n, d) {
    s = substr(json, pos, 4)
    if (length(s) != 4 || s ~ /[^0-9a-fA-F]/) fail()
    n = 0
    for (i = 1; i <= 4; i++) {
        d = index("0123456789abcdef", tolower(substr(s, i, 1))) - 1
        n = n * 16 + d
    }
    pos += 4
    return n
}
function utf8(n) {
    if (n == 0) fail()
    if (n < 128) return sprintf("%c", n)
    if (n < 2048) return sprintf("%c%c", 192 + int(n / 64), 128 + n % 64)
    if (n < 65536) return sprintf("%c%c%c", 224 + int(n / 4096), 128 + int(n / 64) % 64, 128 + n % 64)
    return sprintf("%c%c%c%c", 240 + int(n / 262144), 128 + int(n / 4096) % 64, 128 + int(n / 64) % 64, 128 + n % 64)
}
function string(    value, c, escaped, n, low) {
    if (substr(json, pos++, 1) != "\"") fail()
    value = ""
    while (pos <= length(json)) {
        c = substr(json, pos++, 1)
        if (c == "\"") return value
        if (c ~ /[\001-\037]/) fail()
        if (c != "\\") { value = value c; continue }
        escaped = substr(json, pos++, 1)
        if (escaped == "\"" || escaped == "\\" || escaped == "/") value = value escaped
        else if (escaped == "n") value = value "\n"
        else if (escaped == "r") value = value "\r"
        else if (escaped == "t") value = value "\t"
        else if (escaped == "b") value = value sprintf("%c", 8)
        else if (escaped == "f") value = value sprintf("%c", 12)
        else if (escaped == "u") {
            n = hex4()
            if (n >= 55296 && n <= 56319) {
                if (substr(json, pos, 2) == "\\u") {
                    pos += 2; low = hex4()
                    if (low >= 56320 && low <= 57343) n = 65536 + (n - 55296) * 1024 + low - 56320
                    else { pos -= 6; n = 65533 }
                } else n = 65533
            } else if (n >= 56320 && n <= 57343) n = 65533
            value = value utf8(n)
        } else fail()
    }
    fail()
}
{ json = json $0 "\n" }
END {
    if (bad) exit 1
    out = ENVIRON["AMY_MAILBOX_WORK"]
    if (out == "") fail()
    pos = 1; space()
    if (substr(json, pos++, 1) != "{") fail()
    while (1) {
        space(); key = string(); space()
        if (key !~ /^(id|from|to|ticket|createdAt|body)$/ || key in fields) fail()
        if (substr(json, pos++, 1) != ":") fail()
        space()
        if (key == "ticket" && substr(json, pos, 4) == "null") { value = ""; pos += 4 }
        else value = string()
        fields[key] = value
        space(); delimiter = substr(json, pos++, 1)
        if (delimiter == "}") break
        if (delimiter != ",") fail()
    }
    space()
    if (pos <= length(json)) fail()
    if (length(fields["id"]) != 46 || substr(fields["id"], 1, 13) ~ /[^0-9]/ || substr(fields["id"], 14, 1) != "-" || substr(fields["id"], 15) ~ /[^a-f0-9]/) fail()
    if (fields["to"] != "amy" || fields["from"] != "ops" || !("body" in fields) || fields["body"] == "" || !("createdAt" in fields) || !("ticket" in fields)) fail()
    printf "%s\n", fields["id"] > (out "/id")
    printf "%s\n", fields["from"] > (out "/from")
    printf "%s", fields["body"] > (out "/body")
}
