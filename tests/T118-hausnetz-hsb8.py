#!/usr/bin/env python3
"""OPS-506: offline hsb8 declaration, access, independent pin and backup contracts."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parent.parent
os.chdir(REPO)


def evaluate(expression):
    return json.loads(subprocess.check_output([
        "nix-instantiate", "--eval", "--strict", "--json", "--expr", expression,
    ], text=True))


for source in ("flake.nix", "hosts/hsb8/configuration.nix", "hosts/hsb8/docker/compose-spec.nix"):
    subprocess.run(["nix-instantiate", "--parse", source], check=True, stdout=subprocess.DEVNULL)

declared = evaluate('''
  let
    host = import ./hosts/hsb8/configuration.nix {
      pkgs.stdenv.hostPlatform.system = "fixture";
      pkgs.runCommand = _: _: _: "hostdash-fixture";
      pkgs.iptables = "/nix/store/iptables-fixture";
      pkgs.writeShellScript = _: script: script;
      lib.mkForce = x: x;
      lib.optionals = condition: values: if condition then values else [];
      inputs.hausnetz-hsb8.nixosModules.default = "hausnetz-hsb8-fixture";
      inputs.hausnetz-hsb8.outPath = "/nix/store/hausnetz-hsb8-source-fixture";
      inputs.inspr-modules.nixosModules.ssh-authorized = "ssh-fixture";
      config = {};
    };
    compose = import ./hosts/hsb8/docker/compose-spec.nix;
  in {
    imports = map toString host.imports;
    service = host.services.hausnetz;
    limits = host.systemd.services.hausnetz.serviceConfig;
    hausnetzRequires = host.systemd.services.hausnetz.requires;
    hausnetzAfter = host.systemd.services.hausnetz.after;
    tailnetGuard = host.systemd.services.hausnetz-tailnet-guard;
    composeAfter = host.nixcfg.composeStack.extraAfter;
    sourceDependencies = map toString host.system.extraDependencies;
    firewall = host.networking.firewall;
    frontPage = toString host.environment.etc."hostdash-nginx.conf".source;
    proxy = toString host.environment.etc."hsb8-home-hausnetz.conf".source;
    restartTriggers = map toString host.nixcfg.composeStack.extraRestartTriggers;
    home = compose.services.hsb8-home;
    backup = compose.services.restic-cron-hetzner;
  }
''')
service = declared["service"]
assert "hausnetz-hsb8-fixture" in declared["imports"]
assert not any("hostdash-status.nix" in path for path in declared["imports"])
assert service == {
    "enable": True,
    "listen": "0.0.0.0:8377",
    "hostdashSources": {"hsb8": "http://192.168.1.100/"},
    "firewallInterfaces": ["br-+", "docker0"],
    "starlink": False,
    "discovery": {
        "openFirewallMdns": True,
        "openFirewallSsdp": True,
        "mdnsInterfaces": ["enp2s0f0"],
        "leasesFile": "/var/lib/AdGuardHome/data/leases.json",
    },
}
assert declared["limits"] == {"Type": "exec", "MemoryMax": "512M", "CPUQuota": "50%", "Nice": 10}
assert declared["composeAfter"] == ["hausnetz.service"]
assert "/nix/store/hausnetz-hsb8-source-fixture" in declared["sourceDependencies"]
assert 8377 not in declared["firewall"]["allowedTCPPorts"]
assert not {5353, 1901}.intersection(declared["firewall"]["allowedUDPPorts"])
# OPS-506: the guard owns these rules independently of the firewall lifecycle.
guard = declared["tailnetGuard"]
assert guard["wantedBy"] == ["multi-user.target"]
assert guard["after"] == ["network-pre.target"]
assert guard["before"] == ["hausnetz.service"]
assert set(guard) == {"wantedBy", "after", "before", "serviceConfig"}
guard_config = guard["serviceConfig"]
assert guard_config["Type"] == "oneshot"
assert guard_config["RemainAfterExit"] is True
assert set(guard_config) == {"Type", "RemainAfterExit", "ExecStart", "ExecStop"}
assert declared["hausnetzRequires"] == ["hausnetz-tailnet-guard.service"]
assert declared["hausnetzAfter"] == ["hausnetz-tailnet-guard.service"]
for option in ("extraCommands", "extraStopCommands"):
    assert "OPS-506" not in declared["firewall"].get(option, ""), option

# Require exact interface-scoped rules, checked insertion and duplicate cleanup.
start_commands, stop_commands, rule_keys = ["set -eu"], ["set -eu"], []
for binary in ("iptables", "ip6tables"):
    command = f"/nix/store/iptables-fixture/bin/{binary} -t raw"
    for ports, comment in (
        ("-p tcp --dport 8377", "OPS-506-hausnetz-http"),
        ("-p udp -m multiport --dports 5353,1901", "OPS-506-hausnetz-discovery"),
    ):
        rule = (f'PREROUTING -i tailscale0 {ports} '
                f'-m comment --comment "{comment}" -j DROP')
        start_commands.append(
            f"{command} -C {rule} 2>/dev/null || "
            f"{command} -I {rule}"
        )
        stop_commands.extend([
            f"while {command} -C {rule} 2>/dev/null; do",
            f"{command} -D {rule} 2>/dev/null || true",
            "done",
        ])
        rule_keys.append(f"{binary}:{comment}")


def script_commands(script):
    return [" ".join(line.split()) for line in script.replace("\\\n", " ").splitlines()
            if line.strip()]


assert script_commands(guard_config["ExecStart"]) == start_commands
assert script_commands(guard_config["ExecStop"]) == stop_commands

# Execute the declared scripts against fake iptables binaries, never host rules.
with tempfile.TemporaryDirectory(prefix="ops506-guard-") as directory:
    root = Path(directory)
    (root / "bin").mkdir()
    state = root / "rules.json"
    fixture = f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
state = Path(os.environ["OPS506_RULE_STATE"])
rules = json.loads(state.read_text())
key = Path(sys.argv[0]).name + ":" + sys.argv[sys.argv.index("--comment") + 1]
action = sys.argv[3]
count = rules.get(key, 0)
if action == "-C":
    sys.exit(0 if count else 1)
if action == "-I":
    if key == os.environ.get("OPS506_FAIL_RULE"):
        sys.exit(42)
    rules[key] = count + 1
elif action == "-D":
    if not count:
        sys.exit(1)
    rules[key] = count - 1
else:
    sys.exit(2)
state.write_text(json.dumps(rules))
'''
    for binary in ("iptables", "ip6tables"):
        path = root / "bin" / binary
        path.write_text(fixture)
        path.chmod(0o700)
    child_env = dict(os.environ, OPS506_RULE_STATE=str(state), OPS506_FAIL_RULE="")

    def run_guard(action):
        script = guard_config[action].replace("/nix/store/iptables-fixture", directory)
        return subprocess.run(["bash", "-c", script], env=child_env,
                              capture_output=True, text=True, timeout=10)

    state.write_text("{}")
    for _ in range(2):
        result = run_guard("ExecStart")
        assert result.returncode == 0, result.stderr
        assert json.loads(state.read_text()) == dict.fromkeys(rule_keys, 1)
    state.write_text(json.dumps(dict.fromkeys(rule_keys, 3)))
    for _ in range(2):
        result = run_guard("ExecStop")
        assert result.returncode == 0, result.stderr
        assert not any(json.loads(state.read_text()).values())
    for index, key in enumerate(rule_keys):
        state.write_text("{}")
        child_env["OPS506_FAIL_RULE"] = key
        result = run_guard("ExecStart")
        assert result.returncode == 42, (key, result.stderr)
        assert json.loads(state.read_text()) == dict.fromkeys(rule_keys[:index], 1)

host_source = Path("hosts/hsb8/configuration.nix").read_text()
assert 'leasesFile = if enableAdGuard then "/var/lib/AdGuardHome/data/leases.json" else null;' in host_source
assert "hausnetz_deploy" not in host_source and "hsb8-hausnetz-" not in host_source
home = declared["home"]
assert home.get("network_mode", "bridge") == "bridge"
assert home["ports"] == ["80:80"]
assert home["extra_hosts"] == ["host.docker.internal:host-gateway"]
assert "/etc/hostdash/hsb8/share/hostdash-hsb8:/usr/share/nginx/html:ro" in home["volumes"]
for source, target in (("hostdash-nginx.conf", "conf.d/default.conf"),
                       ("hsb8-home-hausnetz.conf", "hostdash-extra/hausnetz.conf")):
    assert f"/etc/{source}:/etc/nginx/{target}:ro" in home["volumes"]
for key, name in (("frontPage", "front-page-nginx.conf"), ("proxy", "hsb8-home-hausnetz.conf")):
    assert declared[key].endswith("/hosts/hsb8/docker/" + name)
    assert declared[key] in declared["restartTriggers"]
assert not any("hostdash-status" in volume for volume in home["volumes"])

lock = json.loads(Path("flake.lock").read_text())
assert lock["nodes"][lock["root"]]["inputs"]["hausnetz-hsb8"] == "hausnetz-hsb8"
pin = lock["nodes"]["hausnetz-hsb8"]
assert pin["inputs"] == {"nixpkgs": ["nixpkgs"]}
for key in ("locked", "original"):
    assert pin[key]["rev"] == "23c5b4581a3909db1749fb66fd201665d5099645"
    assert pin[key]["url"] == "ssh://git@github.com/inspr-at/hausnetz"
assert pin["locked"]["narHash"] == "sha256-RKue1NxotTIJB1WZ3h+aX1gvCctysst9rRiDShXmUNI="
assert pin["locked"]["lastModified"] == 1793263040
flake = evaluate("(import ./flake.nix).inputs.hausnetz-hsb8")
assert flake["url"] == "git+ssh://git@github.com/inspr-at/hausnetz?rev=" + pin["locked"]["rev"]
assert flake["inputs"]["nixpkgs"]["follows"] == "nixpkgs"
# Run both real auto-update selectors: neither hausnetz pin may be selected.
for path in (".github/workflows/update-flake-lock.yml", "scripts/prepare-pharos-system-update.sh"):
    selector = re.search(r"jq -r '([^']+)' flake.lock", Path(path).read_text())[1]
    selected = subprocess.check_output(["jq", "-r", selector], input=json.dumps(lock), text=True).split()
    assert "hausnetz" not in selected and "hausnetz-hsb8" not in selected
    assert "nixpkgs" in selected

# Host checks need the key for hsb0/hsb8; settings always evaluates hsb8.
for workflow, condition in (
    ("check", "matrix.host == 'hsb0' || matrix.host == 'hsb8'"),
    ("pharos-host-settings", None),
):
    text = Path(f".github/workflows/{workflow}.yml").read_text()
    steps = re.split(r"^      - ", text, flags=re.M)[1:]
    # check.yml also has a separate key step for the private contract shard.
    key_step, = [step for step in steps
                 if step.startswith("name: Read private hausnetz inputs ")
                 and "uses: ./.github/actions/hausnetz-input\n" in step]
    if condition is None:
        assert not re.search(r"^        if:", key_step, re.M), workflow
    else:
        assert f"        if: {condition}\n" in key_step, workflow
    evaluation = ("      - name: Run nix eval for" if workflow == "check" else
                  "      - name: Regenerate and commit declared hsb8 manifest")
    assert text.index(key_step) < text.index(evaluation), workflow
    if workflow == "pharos-host-settings":
        assert text.index(evaluation) < text.index("      - name: Validate schema and target configuration"), workflow

# These fleet-wide evaluations already install the key unconditionally.
for workflow in ("pharos-host-removal", "pharos-system-update"):
    text = Path(f".github/workflows/{workflow}.yml").read_text()
    steps = re.split(r"^      - ", text, flags=re.M)[1:]
    key_step, = [step for step in steps if "uses: ./.github/actions/hausnetz-input" in step]
    assert not re.search(r"^        if:", key_step, re.M), workflow

front = Path(declared["frontPage"]).read_text()
proxy = Path(declared["proxy"]).read_text()
acl = re.compile(r"allow 192\.168\.1\.0/24;\s*allow 100\.64\.0\.0/10;\s*deny all;")


def locations(text):
    blocks = {}
    for match in re.finditer(r"location\s+([^\n{]+)\s*\{", text):
        depth, end = 1, match.end()
        while depth:
            depth += (text[end] == "{") - (text[end] == "}")
            end += 1
        blocks[match[1].strip()] = text[match.end():end - 1]
    return blocks


front_locations, proxy_locations = locations(front), locations(proxy)
assert set(front_locations) == {"= /hostdash", "@hostdash_redirect", "/hostdash/", "= /config.js", "= /manifest.json"}
assert set(proxy_locations) == {"= /ops", "/ops/", "@hausnetz_ops_redirect", "= /api/import", "/"}
for name, body in (front_locations | proxy_locations).items():
    assert acl.search(body), name
    assert len(re.findall(r"^\s*(?:allow|deny)\s", body, re.M)) == 3, name
for name, blocks, destination in (("= /hostdash", front_locations, "@hostdash_redirect"),
                                 ("= /ops", proxy_locations, "@hausnetz_ops_redirect"),
                                 ("/ops/", proxy_locations, "@hausnetz_ops_redirect")):
    assert f'try_files "" {destination};' in blocks[name]
    assert not re.search(r"^\s*return\s", blocks[name], re.M), name
assert "return 301 /hostdash/$is_args$args;" in front_locations["@hostdash_redirect"]
assert "alias /usr/share/nginx/html/;" in front_locations["/hostdash/"]
assert "include /etc/nginx/hostdash-extra/*.conf;" in front
# Preserve hsb0's method/body-safe redirects, limits, headers and proxy behavior.
reference = locations(Path("hosts/hsb0/docker/hsb0-home-hausnetz.conf").read_text())


def without_acl_comments(body):
    return [line.strip() for line in body.splitlines()
            if line.strip() and not re.match(r"\s*(#|allow |deny )", line)]


for name in reference:
    assert without_acl_comments(proxy_locations[name]) == without_acl_comments(reference[name]), name

assert "/var/lib/hausnetz:/backup/var/lib/hausnetz:ro" in declared["backup"]["volumes"]
# Execute the real backup wrapper with a fake restic; no server, credentials or repository touched.
with tempfile.TemporaryDirectory(prefix="ops506-backup-") as directory:
    root = Path(directory)
    restic = root / "restic"
    arguments = root / "arguments"
    restic.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$OPS506_ARGS"\nexit "${OPS506_EXIT:-0}"\n')
    restic.chmod(0o700)
    child_env = dict(os.environ, RESTIC_BIN=str(restic), OPS506_ARGS=str(arguments),
                     MAIL_TO="", PHAROS_BACKUP_STATUS_FILE="")
    for code in (0, 3):
        child_env["OPS506_EXIT"] = str(code)
        result = subprocess.run(["sh", "hosts/hsb8/docker/restic-cron/hetzner/run_backup.sh"],
                                env=child_env, capture_output=True, text=True)
        assert result.returncode == code, result.stderr
        assert arguments.read_text().splitlines() == [
            "backup", "--host", "hsb8", "--exclude", "*/cache/*", "--exclude", "*.log*",
            "/backup/srv/hsb8/mounts/homeassistant", "/backup/srv/hsb8/mounts/mosquitto",
            "/backup/var/lib/hausnetz", "/backup/etc",
        ]

print("OPS-506 offline host, pin, tailnet guard lifecycle/failure, nginx access/proxy and backup contracts: OK")
