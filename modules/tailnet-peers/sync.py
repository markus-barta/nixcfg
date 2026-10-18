#!/usr/bin/env python3
"""OPS-384: bounded host-only tailnet admission, no container control socket."""
import argparse
import fcntl
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import time

CHAINS = (("paper-desk", 8470), ("agent-mailbox", 8471))
NETWORK = ipaddress.ip_network("100.64.0.0/10")


def tailnet(ip):
    try:
        return isinstance(ip, str) and ipaddress.ip_address(ip) in NETWORK
    except ValueError:
        return False


def select(status, rules, previous, now, stale_seconds, reserved):
    if (not isinstance(status, dict) or status.get("BackendState") != "Running"
            or not isinstance(status.get("Peer"), dict)):
        raise ValueError("status unavailable")
    current, online, occupied, issues = {}, {}, set(), []
    address_counts = {}
    for peer in status["Peer"].values():
        if isinstance(peer, dict) and isinstance(peer.get("TailscaleIPs"), list):
            for ip in peer["TailscaleIPs"]:
                if isinstance(ip, str):
                    occupied.add(ip)
                    address_counts[ip] = address_counts.get(ip, 0) + 1
    for key, peer in status["Peer"].items():
        if not isinstance(peer, dict):
            issues.append("hsb0:8470/8471 malformed tailnet peer skipped")
            continue
        tags = peer.get("Tags") if peer.get("Tags") is not None else []
        if not isinstance(tags, list):
            issues.append("hsb0:8470/8471 malformed tailnet peer tags skipped")
            continue
        matches = [rule for rule in rules if rule["tag"] in tags
                   and (not rule.get("host") or rule["host"] == peer.get("HostName"))]
        tagged = any(rule["tag"] in tags for rule in rules)
        if not tagged:
            # Present without its identity tag: revoke immediately, not after grace.
            continue
        name = peer.get("HostName", "")
        if not isinstance(name, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}", name):
            issues.append("hsb0:8470/8471 malformed tagged tailnet hostname skipped")
            continue
        addresses = peer.get("TailscaleIPs")
        if not isinstance(addresses, list):
            issues.append(f"{name}:8470/8471 malformed tagged tailnet addresses skipped")
            continue
        ips = [ip for ip in addresses if tailnet(ip)]
        if not ips:
            issues.append(f"{name}:8470/8471 tagged tailnet peer without IPv4 skipped")
            continue
        if peer.get("Online") is True:
            online.update({ip: name for ip in ips})
        if not matches:
            # Alert on tagged online peers excluded by a hostname rule as well.
            continue
        if len({rule["identity"] for rule in matches}) != 1:
            issues.append(f"{name}:8470/8471 ambiguous tailnet identity skipped")
            continue
        if any(ip in reserved or address_counts[ip] > 1 for ip in ips):
            issues.append(f"{name}:8470/8471 reserved or duplicate tailnet address skipped")
            continue
        if len(current) + len(ips) > 32:
            issues.append(f"{name}:8470/8471 tailnet admission limit reached; peer skipped")
            continue
        for ip in ips:
            row = dict(node=key, identity=matches[0]["identity"], host=name, seen=now)
            current[ip] = row
    for ip, row in previous.items():
        if row["node"] not in status["Peer"] and now - row["seen"] <= stale_seconds:
            if ip not in occupied and not any(
                    item["host"] == row["host"] and item["identity"] == row["identity"]
                    for item in current.values()):
                if len(current) < 32:
                    current[ip] = row
    return current, online, issues


def reconcile(status, rules, previous, now, stale_seconds, reserved):
    try:
        selected, online, issues = select(status, rules, previous, now, stale_seconds, reserved)
        # Missing nodes get a bounded grace, including a wholly empty valid map.
        # Explicit tag removal is authoritative; daemon/parse errors never age out.
        missing = any(row["node"] not in status["Peer"] for row in previous.values())
        tagged = any(rule["tag"] in (peer.get("Tags") or [])
                     and (not rule.get("host") or rule["host"] == peer.get("HostName"))
                     for peer in status["Peer"].values() if isinstance(peer, dict)
                     and isinstance(peer.get("Tags") or [], list) for rule in rules)
        return selected, online, missing and not tagged, issues
    except (ValueError, TypeError, KeyError):
        return previous, {}, True, []


def snapshot(rows):
    return {"schema": 1, "peers": {ip: row["identity"] for ip, row in sorted(rows.items())}}


def admitted_nodes(rows):
    return sorted((ip, row["node"], row["host"], row["identity"]) for ip, row in rows.items())


def validate_state(state):
    if not isinstance(state, dict) or not isinstance(state.get("rows", {}), dict):
        raise ValueError("state malformed")
    for ip, row in state.get("rows", {}).items():
        if (not tailnet(ip) or not isinstance(row, dict)
                or not isinstance(row.get("node"), str)
                or not isinstance(row.get("host"), str)
                or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}", row["host"])
                or not isinstance(row.get("identity"), str)
                or not re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", row["identity"])
                or not isinstance(row.get("seen"), (int, float))
                or not math.isfinite(row["seen"])):
            raise ValueError("state row malformed")
    if len(state.get("rows", {})) > 32:
        raise ValueError("state too large")


def restore_rules(rows, address):
    # ACCEPT terminates the raw table, unlike RETURN which would hit the parent's DROP.
    raw = ["*raw"]
    filt = ["*filter"]
    for prefix, port in CHAINS:
        chain = prefix + "-dyn"
        raw.extend([f":{chain} - [0:0]", f"-F {chain}"])
        filt.extend([f":{chain}-fw - [0:0]", f"-F {chain}-fw"])
        for ip in sorted(rows):
            raw.append(f"-A {chain} -s {ip} -j ACCEPT")
            filt.append(f"-A {chain}-fw -i tailscale0 -s {ip} -d {address} -p tcp --dport {port} -j ACCEPT")
    return "\n".join(raw + ["COMMIT"] + filt + ["COMMIT", ""])


def atomic_json(path, value, mode):
    temporary = path.with_suffix(".new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "w") as handle:
        os.fchmod(handle.fileno(), mode)
        json.dump(value, handle, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def run(argv, data=None):
    return subprocess.run(argv, input=data, text=True, capture_output=True, timeout=12, check=True).stdout


def counters(text):
    result = {}
    for prefix, port in CHAINS:
        match = re.search(r"^\[(\d+):\d+\] -A " + prefix
                          + r'-peers .*--comment "?tailnet-refused-' + str(port)
                          + r'"? -j DROP$', text, re.M)
        if match is None:
            raise ValueError("refusal counter missing")
        result[str(port)] = int(match[1])
    return result


def has_rule(text, chain, required):
    """Match the canonical iptables-save form, independent of option ordering."""
    for line in text.splitlines():
        tokens = shlex.split(re.sub(r"^\[\d+:\d+\] ", "", line))
        tokens = [token.removesuffix("/32") for token in tokens]
        if tokens[:2] != ["-A", chain]:
            continue
        if all(flag in tokens and tokens.index(flag) + 1 < len(tokens)
               and tokens[tokens.index(flag) + 1] == value for flag, value in required.items()):
            return True
    return False


def synchronize(cfg, root, lock_path, now, deliver):
    try:
        _synchronize(cfg, root, lock_path, now, deliver)
        return True
    except Exception:
        # State corruption, write failures and unexpected probe/snapshot errors
        # must use the same adapter as ordinary failures, without raw payloads.
        message = "hsb0:8470/8471 tailnet admission sync crashed; check service journal and state storage"
        print(message, flush=True)
        deliver(message, "ops384-sync-crashed")
        return False


def _synchronize(cfg, root, lock_path, now, deliver):
    with open(lock_path, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            state = json.loads((root / "state.json").read_text())
        except FileNotFoundError:
            state = {}
        validate_state(state)
        previous = state.get("rows", {})
        notice_fingerprint = ""
        notices = set()
        try:
            status = json.loads(run([cfg["tailscale"], "status", "--json"]))
        except (OSError, ValueError, subprocess.SubprocessError):
            status = None
        rows, online, failed, issues = reconcile(status, cfg["rules"], previous, now,
                                          cfg["staleSeconds"], cfg["reserved"])
        if failed:
            issues.append("hsb0:8470/8471 tailnet identity status unavailable or incomplete; retaining last good admission subject to missing-peer grace")
        try:
            rules = restore_rules(rows, cfg["address"])
            run([cfg["restore"], "--wait", "5", "--noflush", "--test"], rules)
            run([cfg["restore"], "--wait", "5", "--noflush"], rules)
            atomic_json(root / "peers.json", snapshot(rows), 0o644)
            state["rows"] = rows
            if admitted_nodes(rows) != admitted_nodes(previous):
                notice_fingerprint = json.dumps([admitted_nodes(previous), admitted_nodes(rows)], sort_keys=True)
                notices.add("hsb0:8470/8471 admitted tailnet node set changed")
                for rule in cfg["rules"]:
                    nodes = {row["node"] for row in rows.values()
                             if row["identity"] == rule["identity"]
                             and (not rule.get("host") or row["host"] == rule["host"])}
                    if len(nodes) > 1:
                        notices.add(f"hsb0:8470/8471 {len(nodes)} admitted nodes match one tailnet identity rule")
                issues.extend(sorted(notices))
            # Check the installed chains and the published snapshot, not just subprocess success.
            published = json.loads((root / "peers.json").read_text())
            raw = run([cfg["save"], "-c", "-t", "raw"])
            filt = run([cfg["save"], "-c", "-t", "filter"])
            for ip, host in online.items():
                admitted = ip in rows and published.get("peers", {}).get(ip) == rows[ip]["identity"]
                for prefix, port in CHAINS:
                    admitted = admitted and all([
                        has_rule(raw, prefix + "-dyn", {"-s": ip, "-j": "ACCEPT"}),
                        has_rule(raw, prefix + "-peers", {"-j": prefix + "-dyn"}),
                        has_rule(raw, "PREROUTING", {"-i": "tailscale0", "-d": cfg["address"],
                                 "-p": "tcp", "--dport": str(port), "-j": prefix + "-peers"}),
                        has_rule(filt, "nixos-fw", {"-j": prefix + "-dyn-fw"}),
                        has_rule(filt, prefix + "-dyn-fw", {"-i": "tailscale0", "-s": ip, "-d": cfg["address"],
                                 "-p": "tcp", "--dport": str(port), "-j": "ACCEPT"}),
                    ])
                if not admitted:
                    failed = True
                    issues.append(f"{host}:8470/8471 online tailnet peer not admitted")
            counts = counters(raw)
            for port, count in counts.items():
                if count > 0 and count != state.get("counters", {}).get(port, 0):
                    issues.append(f"hsb0:{port} refused tailnet packets")
            state["counters"] = counts
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
            failed = True
            issues.append("hsb0:8470/8471 admission sync failed")
            for host in sorted(set(online.values())):
                issues.append(f"{host}:8470/8471 online tailnet peer not admitted")
        if failed:
            state.setdefault("failureSince", now)
            if now - state["failureSince"] >= 120:
                issues.append("hsb0:8470/8471 identity sync failing for at least two minutes")
        else:
            state.pop("failureSince", None)
        # Persist pending alerts so relay failure or a restart cannot lose a refusal.
        pending = state.setdefault("pending", {})
        delivered = state.setdefault("delivered", {})
        for message in issues:
            print(message, flush=True)
            key = hashlib.sha256((message + (notice_fingerprint if message in notices else "")).encode()).hexdigest()[:24]
            if now - delivered.get(key, 0) >= 300:
                pending.setdefault(key, {"message": message, "since": now})
        atomic_json(root / "state.json", state, 0o600)
    # Do not hold the firewall lock while a relay queues email.
    if pending:
        # One bounded relay call per tick; a slow receiver cannot starve identity sync.
        batch = "\n".join(row["message"] for _, row in sorted(pending.items()))
        identifier = "ops384-" + hashlib.sha256(json.dumps(pending, sort_keys=True).encode()).hexdigest()[:24]
        if deliver(batch, identifier):
            delivered.update({key: now for key in pending})
            pending.clear()
        atomic_json(root / "state.json", state, 0o600)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--notification-config", required=True)
    args = parser.parse_args()
    cfg = json.loads(Path(args.config).read_text())

    def deliver(message, identifier):
        try:
            from notification_delivery import email_sender, private_config
            sender = email_sender(private_config(args.notification_config)["email"],
                                  cfg["docker"], subject="Tailnet paper desk admission needs attention")
            return sender(message, identifier)
        except (OSError, ValueError, KeyError, TypeError):
            print("hsb0:8470/8471 existing notification adapter unavailable", flush=True)
            return False

    if not synchronize(cfg, Path("/run/tailnet-peers"), "/run/lock/tailnet-peer-sync.lock", time.time(), deliver):
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never print subprocess output, peer JSON or private notification configuration.
        print("hsb0:8470/8471 tailnet admission sync failed", flush=True)
        raise SystemExit(1)
