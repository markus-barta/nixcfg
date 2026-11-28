"""OPS-737 contracts; evaluate pinned inputs without builds or touching real HOME."""
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
LOCK = json.loads((REPO / "flake.lock").read_text())
BEGIN = "<!-- inspr.agent-kernel BEGIN -->"
END = "<!-- inspr.agent-kernel END -->"
PUBLIC = ".claude/kernel/AGENTS-KERNEL.md"
PRIVATE = ".claude/kernel/AGENTS-KERNEL-PRIVATE.md"
IMPORTS = f"@~/{PUBLIC}\n@~/{PRIVATE}\n"


def locked_source(name):
    """Locate the exact locked fixed-output path, never fetch a missing input."""
    result = subprocess.run(
        ["nix-store", "--print-fixed-path", "--recursive", "sha256",
         LOCK["nodes"][name]["locked"]["narHash"], "source"],
        check=True, capture_output=True, text=True,
    )
    path = Path(result.stdout.strip())
    if not path.is_dir():
        raise SystemExit(f"T129: locked {name} source is not cached: {path}; prefetch outside this offline test")
    return str(path)


NIXPKGS = locked_source("nixpkgs")
PUBLIC_SOURCE = locked_source("inspr-modules")
SELF_REV = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()


def evaluate(enabled=None, legacy=False, self_rev=SELF_REV, module=None, check=True):
    args = {
        "nixpkgs": NIXPKGS, "publicSource": PUBLIC_SOURCE,
        "selfRev": self_rev, "enabled": enabled, "legacy": legacy,
    }
    if module:
        args["modulePath"] = str(module)
    # JSON is passed as a Nix string, never interpolated into a shell command.
    expression = "import ./tests/aeon-operator-mac-eval.nix (builtins.fromJSON " + json.dumps(json.dumps(args)) + ")"
    result = subprocess.run(
        ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression],
        cwd=REPO, capture_output=True, text=True,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout) if check else result


def asset(text, name):
    return text.split(f"OPS737_ASSET_{name}_BEGIN\n", 1)[1].split(f"OPS737_ASSET_{name}_END", 1)[0]


def verify_disabled(cfg, baseline):
    assert cfg == baseline, "disabled option changed the previous HM file set/activation"
    assert cfg["markerHarnesses"] == {"claude": ".claude/CLAUDE.md", "codex": ".codex/AGENTS.md"}
    assert not any("aeon" in name or "/kernel/" in name for name in cfg["files"])


def verify_enabled(cfg):
    files = cfg["files"]
    assert set(files) == set(BASELINE["files"]) | {PUBLIC, PRIVATE, ".config/aeon/operator-macs", ".aeon-operator-kernel.json"}
    assert files[".config/aeon/operator-macs"] == {"text": ""}
    assert files[PUBLIC] == {"source": PUBLIC_SOURCE + "/docs/AGENTS-KERNEL.md"}
    assert files[PRIVATE] == {"source": str(REPO / "modules/uzumaki/agent-kernel-private.md")}
    inventory = json.loads(files[".aeon-operator-kernel.json"]["text"])
    assert set(inventory) == {"kernel_root", "kernel_files"}
    assert inventory["kernel_root"] == "/Users/operator"
    assert Path(inventory["kernel_root"]).is_absolute()
    expected = [
        {"repository": "inspr-at/inspr-modules", "commit": LOCK["nodes"]["inspr-modules"]["locked"]["rev"],
         "path": "docs/AGENTS-KERNEL.md", "relative_file": PUBLIC},
        {"repository": "markus-barta/nixcfg", "commit": SELF_REV,
         "path": "modules/uzumaki/agent-kernel-private.md", "relative_file": PRIVATE},
    ]
    assert inventory["kernel_files"] == expected, "inventory must list only the two single-source Claude files"
    for row in inventory["kernel_files"]:
        assert re.fullmatch(r"[0-9a-f]{40}", row["commit"])
        path = PurePosixPath(row["relative_file"])
        assert not path.is_absolute() and ".." not in path.parts and str(path) == row["relative_file"]
    assert cfg["markerHarnesses"] == {"codex": ".codex/AGENTS.md"}
    activation = cfg["activation"]["aeonOperatorClaudeImports"]
    assert "linkGeneration" in activation["after"], "Claude imports must follow HM link creation"
    assert asset(activation["data"], "aeon-operator-claude-imports") == IMPORTS, "wrong Claude import order"
    for name in BASELINE["files"]:
        assert files[name] == BASELINE["files"][name], name


def execute_activation(cfg, home, directory):
    """Materialize writeText fixtures, then run the actual evaluated shell commands."""
    pattern = re.compile(r"OPS737_ASSET_([^\n]+?)_BEGIN\n(.*?)OPS737_ASSET_\1_END", re.S)

    def materialize(match):
        target = directory / match[1]
        target.write_text(match[2])
        return str(target)

    results = []
    for entry in cfg["activation"].values():
        data = pattern.sub(materialize, entry["data"])
        # escapeShellArg has quoted the composite assignment; use the same
        # evaluated payload via home.file to avoid unescaping nested shell text.
        if data.startswith("payload="):
            payload = directory / "composite"
            payload.write_text(asset(cfg["files"][".pi/agent/AGENTS.md"]["source"], "inspr-agent-kernel.md"))
            commands = data.split("\n/fixture/python3", 1)[1]
            data = "payload=" + shlex.quote(str(payload)) + "\n/fixture/python3" + commands
        data = data.replace("/fixture/python3/bin/python3", shlex.quote(sys.executable))
        results.append(subprocess.run(
            ["bash", "-e", "-c", data], env={**os.environ, "HOME": str(home)},
            check=True, capture_output=True, text=True,
        ))
    return results


def link_kernel_files(cfg, home):
    for path in (PUBLIC, PRIVATE):
        destination = home / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(cfg["files"][path]["source"])


def verify_missing_kernel(enabled):
    """A failed HM link must never replace the existing inline kernel block."""
    with tempfile.TemporaryDirectory(prefix="ops737-missing-kernel-") as temporary:
        root = Path(temporary)
        home, generated = root / "home", root / "generated"
        generated.mkdir()
        link_kernel_files(enabled, home)
        claude = home / ".claude/CLAUDE.md"
        original = f"before\r\n{BEGIN}\r\nexisting inline kernel\r\n{END}\r\nafter\r\n".encode()
        for missing in (PUBLIC, PRIVATE):
            destination = home / missing
            destination.unlink()
            for dangling in (False, True):
                if dangling:
                    destination.symlink_to(root / "missing-source")
                for initial in (original, None):
                    if initial is None:
                        claude.unlink()
                    else:
                        claude.write_bytes(initial)
                    results = execute_activation(enabled, home, generated)
                    if initial is None:
                        assert not claude.exists(), "missing kernel created CLAUDE.md"
                    else:
                        assert claude.read_bytes() == initial, "missing kernel rewrote CLAUDE.md"
                    warning = "".join(result.stderr for result in results)
                    assert "WARNING" in warning and "kernel file missing" in warning
                    assert "leaving CLAUDE.md unchanged" in warning
                if dangling:
                    destination.unlink()
            destination.symlink_to(enabled["files"][missing]["source"])
    print("T129: missing/broken public or private kernel link preserves CLAUDE.md and warns")


def verify_writers(enabled):
    current_payload = asset(BASELINE["files"][".pi/agent/AGENTS.md"]["source"], "inspr-agent-kernel.md")
    imported_payload = b"\n\n".join(Path(enabled["files"][path]["source"]).read_bytes() for path in (PUBLIC, PRIVATE))
    assert current_payload.encode() == imported_payload, "import expansion changed payload bytes"
    script = enabled["activation"]["aeonOperatorClaudeImports"]["data"]
    upstream = BASELINE["activation"]["insprAgentKernelMarkers"]["data"]
    assert asset(script, "aeon-operator-claude-markers.py") == asset(upstream, "inspr-agent-kernel-markers.py")
    with tempfile.TemporaryDirectory(prefix="ops737-writers-") as temporary:
        root = Path(temporary)
        home, generated = root / "home", root / "generated"
        generated.mkdir()
        claude, codex = home / ".claude/CLAUDE.md", home / ".codex/AGENTS.md"
        for destination in (claude, codex):
            destination.parent.mkdir(parents=True, exist_ok=True)
        link_kernel_files(enabled, home)
        cases = [None, "personal only\n", f"before\n\n{BEGIN}\nstale\n{END}\n\nafter\n", f"{BEGIN}\nold\n{END}"]
        for initial in cases:
            if initial is None:
                # All prior fixtures are ours; no real HOME files are touched.
                if claude.exists():
                    claude.unlink()
            else:
                claude.write_text(initial)
            execute_activation(enabled, home, generated)
            first = claude.read_text()
            assert f"{BEGIN}\n{IMPORTS}{END}\n" in first
            if initial and initial.startswith("before"):
                assert first.startswith("before\n\n") and first.endswith("\nafter\n")
            if initial == "personal only\n":
                assert first.endswith("\npersonal only\n")
            execute_activation(enabled, home, generated)
            assert claude.read_text() == first, "enabled activation is not idempotent"
            execute_activation(BASELINE, home, generated)
            restored = claude.read_text()
            assert f"{BEGIN}\n{current_payload.rstrip()}\n{END}\n" in restored
            assert IMPORTS not in restored
            assert codex.read_text() == f"{BEGIN}\n{current_payload.rstrip()}\n{END}\n"
            if initial and initial.startswith("before"):
                assert restored.startswith("before\n\n") and restored.endswith("\nafter\n")
    print("T129: byte-identical payloads; exact upstream writer; personal text, idempotency and disable rewrite passed")


def must_fail(label, action):
    try:
        action()
    except AssertionError:
        print(f"T129: killed mutant: {label}")
        return
    raise AssertionError(f"mutant survived: {label}")


def reject_dirty_config(cfg):
    raise AssertionError("enabled configuration without self.rev must fail evaluation")


BASELINE = evaluate(legacy=True)
verify_disabled(evaluate(), BASELINE)
verify_disabled(evaluate(enabled=False, self_rev=None), BASELINE)
ENABLED = evaluate(enabled=True)
verify_enabled(ENABLED)
verify_writers(ENABLED)
verify_missing_kernel(ENABLED)
for revision in (None, "dirty", "0" * 39):
    result = evaluate(enabled=True, self_rev=revision, check=False)
    assert result.returncode and "requires clean flake revisions" in result.stderr
print("T129: default/explicit OFF match legacy exactly; enabled inventory and missing/invalid revision rejection passed")

# Source mutants evaluate the real changed integration, never a parallel model.
with tempfile.TemporaryDirectory(prefix="ops737-mutants-", dir=REPO / "tests") as temporary:
    root = Path(temporary)
    original = (REPO / "modules/uzumaki/aeon-operator-mac.nix").read_text()
    wrapper = (REPO / "modules/uzumaki/agent-kernel.nix").read_text()
    private_source = str(REPO / "modules/uzumaki/agent-kernel-private.md")
    (root / "aeon-operator-mac.nix").write_text(original.replace("./agent-kernel-private.md", private_source))
    marker_mutant = wrapper.replace(
        '  home.file.".pi/agent/prompts/inspr.md".source =',
        '  home.file.".config/aeon/operator-macs".text = "";\n  home.file.".pi/agent/prompts/inspr.md".source =',
    ).replace("./agent-kernel-private.md", private_source)
    (root / "agent-kernel.nix").write_text(marker_mutant)
    must_fail("marker installed while disabled", lambda: verify_disabled(
        evaluate(enabled=False, module=root / "agent-kernel.nix"), BASELINE))
    for label, before, after, enabled, checker, revision in [
        ("imports run before HM links", 'entryAfter [ "linkGeneration" ]',
         'entryAfter [ "writeBoundary" ]', True, verify_enabled, SELF_REV),
        ("missing kernel guard removed",
         'if [ ! -f "$HOME/.claude/kernel/AGENTS-KERNEL.md" ] || [ ! -f "$HOME/.claude/kernel/AGENTS-KERNEL-PRIVATE.md" ]; then',
         'if false; then', True, verify_missing_kernel, SELF_REV),
        ("inventory lists composite file", 'relative_file = ".claude/kernel/AGENTS-KERNEL.md";',
         'relative_file = ".pi/agent/AGENTS.md";', True, verify_enabled, SELF_REV),
        ("wrong import order", "    @~/.claude/kernel/AGENTS-KERNEL.md\n    @~/.claude/kernel/AGENTS-KERNEL-PRIVATE.md",
         "    @~/.claude/kernel/AGENTS-KERNEL-PRIVATE.md\n    @~/.claude/kernel/AGENTS-KERNEL.md", True, verify_enabled, SELF_REV),
        ("fake commit fallback", "inputs.self.rev or null", 'inputs.self.rev or "0000000000000000000000000000000000000000"', True,
         reject_dirty_config, None),
    ]:
        assert original.count(before) == 1
        changed = original.replace(before, after).replace("./agent-kernel-private.md", private_source)
        (root / "aeon-operator-mac.nix").write_text(changed)
        (root / "agent-kernel.nix").write_text(wrapper.replace("./agent-kernel-private.md", private_source))

        def check_mutant():
            checker(evaluate(enabled=enabled, self_rev=revision, module=root / "agent-kernel.nix"))

        must_fail(label, check_mutant)
print("T129: PASS (scoped module evaluation; no host switch/build performed)")
