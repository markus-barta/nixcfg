#!/usr/bin/env python3
"""Exercise the actual nested Docker mounts on an ephemeral hosted CI runner."""

import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "tests/fixtures/janus-mount-probe"
SPEC = importlib.util.spec_from_file_location("private_files", ROOT / "modules/janus-flow-host/private_files.py")
FILES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FILES)


def command(*argv, ok=True):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=90, check=False)
    if ok and result.returncode:
        raise RuntimeError("synthetic container command failed: " + argv[1])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    # Explicitly refuse operator workstations and production hosts.
    if sys.platform != "linux" or os.geteuid() != 0 or os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        parser.error("requires the root-owned ephemeral GitHub-hosted Linux job")
    if not PROBE.is_file() or PROBE.is_symlink():
        parser.error("missing locally built synthetic probe")
    name = "nix574-synthetic-" + uuid.uuid4().hex
    image = name + ":fixture"
    container_started = False
    image_built = False
    with FILES.FixtureScope() as fixture:
        base = fixture.root
        config = base / "config"
        source = base / "agenix-synthetic"
        target = base / "stable" / "api-key"
        context = base / "image"
        context.mkdir()
        shutil.copyfile(PROBE, context / "probe")
        (context / "probe").chmod(0o755)
        (context / "Dockerfile").write_text("FROM scratch\nCOPY probe /probe\nUSER 100:101\nENTRYPOINT [\"/probe\"]\n")
        source.write_bytes(b"A" * 64)
        source.chmod(0o400)
        FILES.credential(source, target, 100, 101, fixture=fixture)
        FILES.private_directory(config, 100, 101, fixture=fixture)

        def start(*probe_args, detached=False):
            return command(
                "docker", "run", "--rm", *( ["-d"] if detached else [] ),
                "--name", name, "--network", "none", "--read-only",
                "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                "--mount", f"type=bind,source={config},target=/run/janus/flow-host,readonly",
                "--mount", f"type=bind,source={target},target=/run/janus/flow-host/api-key,readonly",
                image, *probe_args, ok=False,
            )

        try:
            command("docker", "build", "--network", "none", "-t", image, str(context))
            image_built = True
            missing = start("A")
            if missing.returncode == 0 or "read-only file system" not in missing.stderr.lower():
                raise RuntimeError("missing mount-target reproduction differed from expected runc refusal")
            # A failed docker run may retain its named, stopped container.
            command("docker", "container", "rm", name, ok=False)
            FILES.placeholder(config / "api-key", 100, 101, fixture=fixture)
            started = start("wait", detached=True)
            if started.returncode:
                raise RuntimeError("nested read-only mounts failed with the published placeholder")
            container_started = True
            command("docker", "exec", name, "/probe", "A")
            inode = target.stat().st_ino
            next_source = base / "agenix-next"
            next_source.write_bytes(b"A" * 64)
            next_source.chmod(0o400)
            os.replace(next_source, source)
            assert FILES.credential(source, target, 100, 101, fixture=fixture) is False
            assert target.stat().st_ino == inode
            command("docker", "exec", name, "/probe", "A")
            next_source.write_bytes(b"B" * 64)
            next_source.chmod(0o400)
            os.replace(next_source, source)
            assert FILES.credential(source, target, 100, 101, fixture=fixture) is True
            # Exact old-bind nlink refusal, not a generic process failure.
            assert command("docker", "exec", name, "/probe", "A", ok=False).returncode == 6
            command("docker", "stop", "-t", "1", name)
            container_started = False
            result = start("B")
            if result.returncode:
                raise RuntimeError("rotated credential failed after normal container recreation")
            print("Janus synthetic mounts: placeholder, read-only boundaries, unchanged inode and rotation passed")
        finally:
            if container_started:
                command("docker", "stop", "-t", "1", name, ok=False)
            command("docker", "container", "rm", name, ok=False)
            if image_built:
                command("docker", "image", "rm", image, ok=False)


if __name__ == "__main__":
    main()
