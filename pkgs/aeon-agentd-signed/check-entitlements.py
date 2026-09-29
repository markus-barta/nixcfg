"""Refuse entitlements that make aeon-agentd refuse Touch ID.

Reads `codesign -d --entitlements - --xml` output on stdin. The daemon reads
get-task-allow, disable-library-validation and allow-dyld-environment-variables
with boolValue, so anything but an explicit <false/> can count as "on". The
plist is parsed structurally (XML entities decoded), and the check fails on
malformed input, a root that is not a dictionary, duplicate keys, or any of the
three keys with a value other than <false/>. Empty input (no entitlements) is
accepted.
"""

import sys
import xml.etree.ElementTree as ET

FORBIDDEN = {
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-dyld-environment-variables",
}


def fail(message):
    print(f"aeon-agentd-signed: {message}", file=sys.stderr)
    sys.exit(1)


def main():
    data = sys.stdin.buffer.read()
    if not data.strip():
        return
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        fail(f"entitlements are not well-formed XML ({error})")
    if root.tag != "plist" or len(root) != 1 or root[0].tag != "dict":
        fail("entitlements root is not a single dictionary")
    children = list(root[0])
    if len(children) % 2:
        fail("entitlements dictionary has a key without a value")
    seen = set()
    for key, value in zip(children[0::2], children[1::2]):
        if key.tag != "key":
            fail(f"entitlements dictionary has <{key.tag}> where a key belongs")
        name = key.text or ""
        if name in seen:
            fail(f"entitlement {name} appears more than once")
        seen.add(name)
        if name in FORBIDDEN and (value.tag != "false" or len(value) or (value.text or "").strip()):
            fail(f"entitlement {name} is not false; the daemon would refuse Touch ID")


if __name__ == "__main__":
    main()
