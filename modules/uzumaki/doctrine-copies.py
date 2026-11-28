"""Install generated doctrine as regular files; preserve foreign entries once."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


def install(destination, source, marker):
    if destination.parent.is_symlink():
        raise ValueError(f"refusing symlinked doctrine parent: {destination.parent}")
    payload = source.read_bytes()
    if not payload.startswith(marker + b"\n"):
        raise ValueError("doctrine source is missing its generated marker")
    exists = os.path.lexists(destination)
    generated = False
    if exists:
        mode = destination.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
            raise ValueError(f"refusing to replace non-file doctrine target: {destination}")
        # Never follow a destination symlink, including one with our marker.
        if stat.S_ISREG(mode):
            with destination.open("rb") as current:
                generated = current.readline() == marker + b"\n"
            if generated and destination.read_bytes() == payload:
                if stat.S_IMODE(mode) != 0o644:
                    destination.chmod(0o644)
                return

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
                destination.rename(backup)
            else:
                # Preserve the foreign inode without a gap at the target path.
                os.link(destination, backup)
        os.replace(temporary, destination)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def main():
    home = Path(sys.argv[1])
    manifest = json.loads(Path(sys.argv[2]).read_text())
    for target in manifest["targets"]:
        destination = home / target["path"]
        try:
            required = target.get("requiredDirectory")
            if required and not (home / required).is_dir():
                print(f"WARNING: skipping doctrine copy; Codex home does not exist: {home / required}", file=sys.stderr)
                continue
            install(destination, Path(target["source"]), manifest["marker"].encode())
        except Exception as error:
            print(f"WARNING: skipping doctrine copy for {destination}: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
