"""Install generated doctrine as regular files; preserve foreign entries once."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


BEGIN = b"<!-- inspr.agent-kernel BEGIN -->"
END = b"<!-- inspr.agent-kernel END -->"


class Refused(ValueError):
    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason


def personal_payload(current, payload, marker):
    """Keep the upstream prefix as bytes, including the END line's terminator."""
    lines = current.splitlines(keepends=True)
    begins = [i for i, line in enumerate(lines) if line.rstrip(b"\r\n") == BEGIN]
    ends = [i for i, line in enumerate(lines) if line.rstrip(b"\r\n") == END]
    if current.count(BEGIN) != 1 or current.count(END) != 1 or len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
        raise Refused("kernel-markers", "refusing missing, duplicated or malformed kernel markers")
    prefix = b"".join(lines[:ends[0] + 1])
    suffix = b"".join(lines[ends[0] + 1:])
    generated = suffix.lstrip(b"\r\n").startswith(marker + b"\n")
    separator = b"\n" if prefix.endswith(b"\n") else b"\n\n"
    return prefix + separator + payload, generated


def install(destination, source, marker, personal_section=False):
    if destination.parent.is_symlink():
        raise Refused("symlink-parent", f"refusing symlinked doctrine parent: {destination.parent}")
    payload = source.read_bytes()
    if not payload.startswith(marker + b"\n"):
        raise Refused("source-marker", "doctrine source is missing its generated marker")
    exists = os.path.lexists(destination)
    generated = False
    if personal_section and (not exists or not stat.S_ISREG(destination.lstat().st_mode)):
        raise Refused("personal-not-regular", f"refusing non-regular personal doctrine target: {destination}")
    if exists:
        mode = destination.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
            raise Refused("non-file", f"refusing to replace non-file doctrine target: {destination}")
        # Never follow a destination symlink, including one with our marker.
        if stat.S_ISREG(mode):
            current = destination.read_bytes()
            if personal_section:
                payload, generated = personal_payload(current, payload, marker)
            else:
                generated = current.startswith(marker + b"\n")
            if generated and current == payload:
                if not personal_section and stat.S_IMODE(mode) != 0o644:
                    destination.chmod(0o644)
                return "unchanged"

    destination.parent.mkdir(parents=True, exist_ok=True)
    # Create in the destination directory: replacement is atomic on its filesystem.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=f".{destination.name}.", dir=destination.parent, delete=False) as staged:
            temporary = Path(staged.name)
            staged.write(payload)
            staged.flush()
            os.fchmod(staged.fileno(), 0o644)
            os.fsync(staged.fileno())
        if exists and not generated:
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            backup = destination.with_name(f"{destination.name}.pre-hm-{stamp}")
            # Never replace a previous backup, even on a timestamp collision.
            while os.path.lexists(backup):
                backup = backup.with_name(backup.name + "-1")
            if stat.S_ISLNK(mode):
                os.symlink(os.readlink(destination), backup)
            else:
                # Preserve the foreign inode without a gap at the target path.
                os.link(destination, backup)
        os.replace(temporary, destination)
        return "installed"
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def write_status(home, results):
    directory = os.path.normpath(os.path.join(home, ".local/state/inspr-doctrine-copies"))
    if not directory.startswith(home + os.sep):
        raise ValueError("refusing doctrine status outside home")
    directory = Path(directory)
    for parent in (directory, *directory.parents):
        if parent == Path(home):
            break
        if parent.is_symlink():
            raise ValueError("refusing symlinked doctrine status directory")
    directory.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".status.", dir=directory, delete=False) as staged:
            temporary = Path(staged.name)
            staged.write(json.dumps({"targets": results}, indent=2).encode() + b"\n")
            staged.flush()
            os.fsync(staged.fileno())
        os.replace(temporary, directory / "status.json")
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main():
    home = os.path.realpath(sys.argv[1])
    # Nix writeText assets share the store root; test assets share a fixture directory.
    asset_root = os.path.dirname(os.path.realpath(__file__))
    manifest_path = os.path.realpath(sys.argv[2])
    if not manifest_path.startswith(asset_root + os.sep):
        raise ValueError("refusing doctrine manifest outside the installer asset root")
    manifest = json.loads(Path(manifest_path).read_text())
    results = []
    for target in manifest["targets"]:
        destination = os.path.normpath(os.path.join(home, target["path"]))
        try:
            if not destination.startswith(home + os.sep):
                raise ValueError("refusing doctrine target outside home")
            destination = Path(destination)
            required = target.get("requiredDirectory")
            required_path = os.path.normpath(os.path.join(home, required or "."))
            if required and not required_path.startswith(home + os.sep):
                raise ValueError("refusing required doctrine directory outside home")
            if required and not Path(required_path).is_dir():
                raise Refused("missing-directory", f"Codex home does not exist: {required_path}")
            outcome = install(destination, Path(target["source"]), manifest["marker"].encode(), target.get("personalSection", False))
        except Exception as error:
            print(f"WARNING: skipping doctrine copy for {destination}: {error}", file=sys.stderr)
            outcome = "skipped:" + (error.reason if isinstance(error, Refused) else type(error).__name__)
        results.append({"path": target["path"], "outcome": outcome, "timestamp": datetime.now(timezone.utc).isoformat()})
    try:
        write_status(home, results)
    except Exception as error:
        print(f"WARNING: could not persist doctrine copy status: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
