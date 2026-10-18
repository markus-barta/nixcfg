#!/usr/bin/env python3
"""OPS-338: cover rename-replaced Traefik mounts, offline and eval-only."""

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "hosts/csb1/docker/traefik/static.yml"
DYNAMIC = STATIC.with_name("dynamic.yml")
EDGE_SCRIPT = ROOT / "hosts/csb1/scripts/render-inspr-edge-config.sh"
FLOW_SCRIPT = EDGE_SCRIPT.with_name("render-shared-flow-config.sh")
EDGE_LABEL = "ops.inspr-edge-inputs-sha256="
FLOW_LABEL = "ops.shared-flow-inputs-sha256="


def file_digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def input_digest(inputs):
    return hashlib.sha256(json.dumps(inputs, separators=(",", ":")).encode()).hexdigest()


def check_label(labels, prefix, digest):
    assert [label for label in labels if label.startswith(prefix)] == [prefix + digest], (
        f"Traefik must carry exactly one {prefix} label matching its inputs"
    )


def read_json(command):
    result = subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, timeout=30, check=False
    )
    # Do not print evaluated configuration or subprocess output on failure.
    assert result.returncode == 0, f"{command[0]}: offline evaluation failed"
    return json.loads(result.stdout)


def main():
    # Stub only module dependencies, retaining the real spec, renderer trigger
    # lists and legacy routing data. Public YAML stands in for ciphertext;
    # synthetic store paths avoid a daemon, derivation builds or secret reads.
    contracts = read_json([
        "nix-instantiate", "--eval", "--strict", "--json", "--expr", """
        let
          recursiveUpdate = left: right:
            left // builtins.mapAttrs (name: value:
              if builtins.hasAttr name left && builtins.isAttrs left.${name}
                 && builtins.isAttrs value
              then recursiveUpdate left.${name} value else value
            ) right;
          evaluate = { ciphertext, generated, legacySalt ? "" }:
            let
              host = import ./hosts/csb1/configuration.nix {
                config = {
                  age.secrets = {
                    csb1-inspr-auth-env = { file = ciphertext; };
                    traefik-variables.file = "fixture-traefik-ciphertext";
                    csb1-aeon-review-app-key.file = "fixture-review-key";
                    csb1-aeon-review-webhook-secret.file = "fixture-review-webhook";
                  };
                  services.inspr.routingEdge.generatedFragmentFile = generated;
                };
                lib = {
                  inherit recursiveUpdate;
                  mkIf = _: value: value;
                  optionals = enabled: values: if enabled then values else [];
                };
                pkgs = {
                  stdenv.hostPlatform.system = "fixture";
                  writeText = name: text:
                    "/nix/store/" + builtins.substring 0 32
                      (builtins.hashString "sha256" (text + legacySalt)) + "-" + name;
                };
                inputs.hostdash.packages.fixture.csb1 = "fixture-hostdash";
              };
              stack = host.nixcfg.composeStack;
              traefik = stack.spec.services.traefik;
            in {
              inherit (stack) postRecreate;
              inherit (traefik) labels volumes command env_file;
              entrypoint = traefik.entrypoint or null;
              edgeInputs = map toString host.systemd.services.inspr-edge-config.restartTriggers;
              flowInputs = map toString host.systemd.services.inspr-shared-flow-config.restartTriggers;
              credentialTriggersReconcile = builtins.elem "fixture-traefik-ciphertext"
                stack.extraRestartTriggers;
            };
          baseline = {
            ciphertext = ./hosts/csb1/docker/traefik/static.yml;
            generated = "/nix/store/fixture-generated-routing.json";
          };
        in map evaluate [
          baseline
          (baseline // { ciphertext = ./hosts/csb1/docker/traefik/dynamic.yml; })
          (baseline // { generated = "/nix/store/fixture-changed-routing.json"; })
          (baseline // { legacySalt = "changed-legacy-fragment"; })
        ]
        """,
    ])
    contract = contracts[0]
    for candidate in contracts:
        assert candidate["postRecreate"] == ["hostdash-auth", "hostdash"], (
            "Traefik must not be force-recreated; retain both HostDash services"
        )
        assert candidate["credentialTriggersReconcile"], (
            "Traefik credential ciphertext must trigger same-switch reconciliation"
        )
        check_label(candidate["labels"], "ops.static-config-sha256=", file_digest(STATIC))
        check_label(candidate["labels"], "ops.dynamic-config-sha256=", file_digest(DYNAMIC))
        edge_inputs = candidate["edgeInputs"]
        flow_inputs = candidate["flowInputs"]
        assert edge_inputs == [str(STATIC if candidate is not contracts[1] else DYNAMIC), str(EDGE_SCRIPT)], (
            "Re-audit edge renderer restartTriggers and hash coverage"
        )
        assert len(flow_inputs) == 3 and flow_inputs[2] == str(FLOW_SCRIPT), (
            "Re-audit shared-flow renderer restartTriggers and hash coverage"
        )
        assert all(path.startswith("/nix/store/") for path in flow_inputs[:2])
        check_label(candidate["labels"], EDGE_LABEL, input_digest([
            file_digest(Path(edge_inputs[0])), file_digest(EDGE_SCRIPT),
        ]))
        check_label(candidate["labels"], FLOW_LABEL, input_digest([
            *flow_inputs[:2], file_digest(FLOW_SCRIPT),
        ]))
    for index, changed_prefix in ((1, EDGE_LABEL), (2, FLOW_LABEL), (3, FLOW_LABEL)):
        before = {label.split("=", 1)[0]: label for label in contract["labels"]}
        after = {label.split("=", 1)[0]: label for label in contracts[index]["labels"]}
        assert before.keys() == after.keys()
        assert [key + "=" for key in before if before[key] != after[key]] == [changed_prefix], (
            "Changing one renderer input must change only its recreate label"
        )

    # Guard expressions too: frozen digests and extra file/ACME reads must fail.
    source = (ROOT / "hosts/csb1/docker/compose-spec.nix").read_text()
    traefik_source = source.split("    traefik = {", 1)[1].split("\n    };", 1)[0]
    for name in ("static", "dynamic"):
        assert f'"ops.{name}-config-sha256=${{builtins.hashFile "sha256" ./traefik/{name}.yml}}"' in traefik_source
    hash_pattern = r'builtins[.]hashFile\s+"sha256"\s+([^\s})]+)'
    assert re.findall(hash_pattern, traefik_source) == ["./traefik/static.yml", "./traefik/dynamic.yml"], (
        "Only checkout config files may be file-hashed in the Traefik spec"
    )
    assert not re.search(r"builtins[.](hashString|readFile)", traefik_source)
    host_source = (ROOT / "hosts/csb1/configuration.nix").read_text()
    overlay = host_source.split("    spec =", 1)[1].split("\n  # The token never", 1)[0]
    assert re.findall(hash_pattern, overlay) == [
        "config.age.secrets.csb1-inspr-auth-env.file",
        "./scripts/render-inspr-edge-config.sh",
        "./scripts/render-shared-flow-config.sh",
    ], "Only renderer source and public ciphertext may be file-hashed in the overlay"
    assert re.findall(r'builtins[.]unsafeDiscardStringContext\s+"\$\{([^}]+)\}"', overlay) == [
        "config.services.inspr.routingEdge.generatedFragmentFile", "legacyFlowFragmentFile",
    ], "Hash both derivation store-path strings without IFD or retained context"
    assert overlay.count('builtins.hashString "sha256"') == 2
    assert "builtins.readFile" not in overlay and "acme" not in overlay.lower()
    assert contract["command"] == "--configFile=/etc/traefik/traefik.yml"
    assert contract["entrypoint"] is None, "Re-audit startup files if the entrypoint changes"
    assert contract["env_file"] == ["/run/agenix/traefik-variables"], (
        "Keep the runtime env_file; Compose hashes resolved credentials, labels must not"
    )

    provider = read_json(["yq", "-o=json", ".providers.file", str(STATIC)])
    assert provider == {"directory": "/etc/traefik/dynamic", "watch": True}, (
        "The file provider must watch every mounted dynamic file"
    )
    mounts = {}
    for volume in contract["volumes"]:
        if isinstance(volume, str):
            source, target, *mode = volume.split(":")
        else:
            source, target = volume["source"], volume["target"]
        assert target not in mounts, "Duplicate Traefik mount target"
        mounts[target] = source
    assert mounts.pop("/etc/traefik/traefik.yml") == "./traefik/static.yml"
    for name in ("acme.json", "acme-http.json"):
        assert mounts.pop(f"/etc/traefik/acme/{name}") == f"./traefik/{name}"
        assert f"./traefik/{name}:/etc/traefik/acme/{name}:rw" in contract["volumes"], (
            "ACME state mounts must remain writable and unchanged"
        )
    assert mounts == {
        "/etc/traefik/dynamic/dynamic.yml": "./traefik/dynamic.yml",
        "/etc/traefik/dynamic/inspr-edge.yml": "/run/inspr-edge/dynamic.yml",
        "/etc/traefik/dynamic/inspr-shared-flow.yml": "/run/inspr-shared-flow/dynamic.yml",
    }, "Re-audit new startup mounts or changed dynamic mount coverage"
    assert all(str(PurePosixPath(target).parent) == provider["directory"] for target in mounts)
    print("OPS-338 Traefik recreation contract OK (static/dynamic/renderer hashes, input changes, credential trigger, rw unhashed ACME)")


if __name__ == "__main__":
    main()
