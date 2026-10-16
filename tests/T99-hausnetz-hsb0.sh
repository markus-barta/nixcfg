#!/usr/bin/env bash
# OPS-207: offline declaration/proxy/CI contract; full merged config checked in CI.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

for source in flake.nix hosts/hsb0/configuration.nix hosts/hsb0/docker/compose-spec.nix tests/hausnetz-hsb0-eval.nix; do
  nix-instantiate --parse "$source" >/dev/null
done

# Evaluate the actual host declarations and compose service without fetching
# inputs or realizing derivations. Only mkBefore needs a value-free stub.
nix-instantiate --eval --strict --json --expr '
  let
    host = import ./hosts/hsb0/configuration.nix {
      pkgs = {}; config = {}; inputs = {};
      lib.mkBefore = x: x;
    };
    compose = import ./hosts/hsb0/docker/compose-spec.nix;
  in {
    service = host.services.hausnetz;
    limits = host.systemd.services.hausnetz.serviceConfig;
    firewall = host.networking.firewall;
    ssh = host.programs.ssh;
    proxySource = toString host.environment.etc."hsb0-home-hausnetz.conf".source;
    home = compose.services.hsb0-home;
  }
' | python3 -c '
import json, sys
c = json.load(sys.stdin)
s, fw, home = c["service"], c["firewall"], c["home"]
assert s["enable"] and s["listen"] == "0.0.0.0:8377"
assert s["firewallInterfaces"] == ["br-+", "docker0"]
assert s["discovery"] == {"openFirewallMdns": True, "mdnsInterfaces": ["enp2s0f0"]}
assert "seed" not in s and "leasesFile" not in s["discovery"] and "extraArgs" not in s
assert fw["enable"] and 8377 not in fw["allowedTCPPorts"] and 5353 not in fw["allowedUDPPorts"]
assert c["limits"] == {"MemoryMax": "512M", "CPUQuota": "50%", "Nice": 10}
assert home.get("network_mode", "bridge") == "bridge"
assert home["extra_hosts"] == ["host.docker.internal:host-gateway"]
assert "/etc/hsb0-home-hausnetz.conf:/etc/nginx/hostdash-extra/hausnetz.conf:ro" in home["volumes"]
assert c["proxySource"].endswith("/hosts/hsb0/docker/hsb0-home-hausnetz.conf")
ssh = c["ssh"]
assert "Match host github.com localuser root" in ssh["extraConfig"]
assert "IdentityFile /root/.ssh/hausnetz_deploy" in ssh["extraConfig"]
assert "IdentitiesOnly yes" in ssh["extraConfig"]
assert ssh["extraConfig"].strip().endswith("Host *")
assert ssh["knownHosts"]["github.com"]["publicKey"] == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
print("OPS-207 evaluated host declarations: OK")
'

python3 - <<'PY'
import json
import re
import subprocess
from pathlib import Path

proxy = Path('hosts/hsb0/docker/hsb0-home-hausnetz.conf').read_text()
assert re.search(r'location = /ops\s*\{\s*absolute_redirect off;\s*return 301 /ops/;', proxy)
assert 'location /ops/ {' in proxy
for directive in ('proxy_pass http://host.docker.internal:8377/;', 'proxy_buffering off;',
                  'proxy_http_version 1.1;', 'proxy_set_header Connection "";',
                  'proxy_read_timeout 1h;', 'proxy_cache off;'):
    assert directive in proxy, directive
assert 'include /etc/nginx/hostdash-extra/*.conf;' in Path('modules/files/hostdash-nginx.conf').read_text()

pin = '1f876f1d28d74d5931f4f3628a90de112a43506c'
assert f'git+ssh://git@github.com/markus-barta/hausnetz?rev={pin}' in Path('flake.nix').read_text()
lock = json.loads(Path('flake.lock').read_text())
assert lock['nodes'][lock['root']]['inputs']['hausnetz'] == 'hausnetz'
node = lock['nodes']['hausnetz']
assert node['inputs'] == {'nixpkgs': ['nixpkgs']}
for source in ('locked', 'original'):
    assert node[source]['type'] == 'git' and node[source]['rev'] == pin
    assert node[source]['url'] == 'ssh://git@github.com/markus-barta/hausnetz'
assert node['locked']['narHash'] == 'sha256-BZyTWNxApPN/K44Bbhub7TNfsziEYLPXaqmizfQ6emM='
imports = [p for p in Path('hosts').rglob('*.nix') if 'inputs.hausnetz.nixosModules.default' in p.read_text()]
assert imports == [Path('hosts/hsb0/configuration.nix')], imports

workflows = ('check', 'pharos-system-update', 'pharos-host-removal', 'pharos-host-settings', 'update-flake-lock')
for name in workflows:
    text = Path(f'.github/workflows/{name}.yml').read_text()
    assert '\nenv:\n  GIT_CONFIG_COUNT: "1"\n' in text, name
    assert 'GIT_CONFIG_KEY_0: url.https://x-access-token:${{ secrets.GH_TOKEN_FOR_UPDATES }}@github.com/.insteadOf' in text, name
    assert 'GIT_CONFIG_VALUE_0: ssh://git@github.com/' in text, name

# Run the selection expression from each real update path against a lock fixture.
fixture = {"root": "root", "nodes": {"root": {"inputs": {"nixpkgs": "nixpkgs", "hausnetz": "hausnetz", "home-manager": "hm", "alias": ["nixpkgs"]}}}}
for path in ('.github/workflows/update-flake-lock.yml', 'scripts/prepare-pharos-system-update.sh'):
    text = Path(path).read_text()
    expression = re.search(r"jq -r '([^']+)' flake.lock", text)[1]
    selection = subprocess.check_output(['jq', '-r', expression], input=json.dumps(fixture).encode()).decode().split()
    assert selection == ['home-manager', 'nixpkgs'], (path, selection)
assert 'inputs: ${{ steps.inputs.outputs.inputs }}' in Path('.github/workflows/update-flake-lock.yml').read_text()
assert 'nix flake update "${update_inputs[@]}"' in Path('scripts/prepare-pharos-system-update.sh').read_text()
ci = Path('.github/workflows/check.yml').read_text()
assert 'bash tests/T99-hausnetz-hsb0.sh' in ci and 'import ./tests/hausnetz-hsb0-eval.nix' in ci
print('OPS-207 proxy and CI contracts: OK')
PY
