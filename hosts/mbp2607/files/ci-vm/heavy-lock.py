#!/usr/bin/env python3
"""OPS-669 detail spec v1: shared host lock; no VM or network operations."""

import datetime
import json
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlparse

OWNER = "hausnetz-ci-vm"
SCHEMA = "mbp2607-heavy-lock.v1"


def utc(seconds):
    return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def alive(pid):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def valid_url(value):
    if not isinstance(value, str):
        return False
    try:
        parsed = urlparse(value)
        return parsed.scheme == "https" and bool(parsed.netloc) and not any(c.isspace() for c in value)
    except ValueError:
        return False


def dead(owner):
    # Unknown PID is not evidence of death. An unreadable/missing record has
    # no process identity at all and follows the spec's directory-mtime rule.
    return not owner or (owner.get("pid") is not None and not alive(owner["pid"]))


def snapshot(path):
    stat = path.lstat()
    if path.is_symlink() or not path.is_dir():
        raise RuntimeError("unsafe heavy lock path")
    owner = {}
    started = stat.st_mtime
    try:
        if (path / "owner.json").is_symlink():
            raise ValueError("symlinked owner")
        data = json.loads((path / "owner.json").read_text())
        if isinstance(data, dict) and data:
            # Independent fields: an optional URL must not discard a valid PID,
            # owner or start time from another participant's record.
            for key in ("schema", "owner", "started_at", "host"):
                if isinstance(data.get(key), str):
                    owner[key] = data[key]
            pid = data.get("pid")
            owner["pid"] = pid if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0 else None
            url = data.get("job_url")
            owner["job_url"] = url if valid_url(url) else "unknown"
            try:
                value = datetime.datetime.fromisoformat(owner["started_at"].replace("Z", "+00:00"))
                if value.utcoffset() == datetime.timedelta(0):
                    started = value.timestamp()
            except (ValueError, KeyError, OverflowError):
                pass
    except (OSError, ValueError, TypeError):
        pass
    return stat, owner, started


def same(path, stat, owner):
    current, data, _ = snapshot(path)
    return (current.st_dev, current.st_ino, data) == (stat.st_dev, stat.st_ino, owner)


def write_owner(path, owner):
    # Readers see either complete version; the private temporary file is never
    # interpreted as a lock record. The shared record must be readable by PAPP.
    fd, name = tempfile.mkstemp(prefix=".owner-", dir=path)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(owner, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(name, path / "owner.json")
    finally:
        if os.path.exists(name):
            os.unlink(name)


def release(path, stat, owner):
    if owner.get("owner") != OWNER or not same(path, stat, owner):
        return False
    (path / "owner.json").unlink()
    path.rmdir()
    return True


def operate(action, path, pid, now, job_url="", hostagent=0):
    if action == "acquire":
        if not valid_url(job_url):
            raise ValueError("acquisition requires an https job_url")
        try:
            path.parent.mkdir(mode=0o1777, parents=True)
        except FileExistsError:
            pass
        else:
            path.parent.chmod(0o1777)
        transitions = []
        for _ in range(3):
            try:
                path.mkdir(mode=0o755)
            except FileExistsError:
                try:
                    stat, owner, started = snapshot(path)
                except FileNotFoundError:
                    continue
                # Caller verified ci is stopped. An unrelated live PID may be
                # reuse, but only for our own residue, never another holder.
                if (owner.get("owner") == OWNER and hostagent == 0
                        and owner.get("pid") is not None
                        and (not alive(owner["pid"]) or owner["pid"] != hostagent)):
                    if release(path, stat, owner):
                        transitions.append("residue-released")
                        continue
                if dead(owner) and now - started > 10800:
                    if owner.get("owner") == OWNER and hostagent != 0:
                        return {"transitions": transitions, "busy": True, "owner": owner}
                    if not same(path, stat, owner):
                        continue
                    stale = path.with_name(path.name + f".stale-{utc(now)}-{pid}")
                    # Never overwrite an earlier quarantine directory.
                    if stale.exists():
                        return {"transitions": transitions, "busy": True, "owner": owner}
                    path.rename(stale)
                    if not same(stale, stat, owner):
                        raise RuntimeError("heavy lock changed during stale rename; quarantined for inspection")
                    transitions.append(f"stale-broken {stale}")
                    continue
                return {"transitions": transitions, "busy": True, "owner": owner}
            else:
                path.chmod(0o755)
                owner = dict(schema=SCHEMA, owner=OWNER, pid=pid, started_at=utc(now), job_url=job_url, host="mbp2607")
                write_owner(path, owner)
                transitions.append("acquired")
                return {"transitions": transitions, "busy": False, "owner": owner}
        raise RuntimeError("heavy lock changed repeatedly")
    if not path.exists():
        if action == "handoff":
            raise RuntimeError("heavy lock disappeared before hostagent handoff")
        return {"transitions": []}
    stat, owner, _ = snapshot(path)
    if action == "residue":
        if (owner.get("owner") == OWNER and hostagent == 0
                and owner.get("pid") is not None
                and (not alive(owner["pid"]) or owner["pid"] != hostagent)
                and release(path, stat, owner)):
            return {"transitions": ["residue-released"]}
        return {"transitions": []}
    if action == "handoff":
        if hostagent <= 0:
            raise RuntimeError("invalid hostagent handoff PID")
        if owner.get("owner") != OWNER or owner.get("pid") != pid or not same(path, stat, owner):
            raise RuntimeError("heavy lock ownership changed before hostagent handoff")
        owner["pid"] = hostagent
        write_owner(path, owner)
        return {"transitions": ["acquired hostagent-handoff"], "owner": owner}
    if action == "release":
        # pid is the exact holder recorded before stop, or the booting tick.
        if owner.get("pid") == pid and release(path, stat, owner):
            return {"transitions": ["released"]}
        return {"transitions": []}
    raise RuntimeError("unknown heavy lock operation")


if __name__ == "__main__":
    try:
        action, path, pid, now, *extra = sys.argv[1:]
        print(json.dumps(operate(action, Path(path), int(pid), int(now),
                                 extra[0] if extra else "", int(extra[1]) if len(extra) > 1 else 0)))
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ci-vm: heavy lock: {exc}", file=sys.stderr)
        sys.exit(1)
