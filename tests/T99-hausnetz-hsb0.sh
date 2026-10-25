#!/usr/bin/env bash
# OPS-207/355: offline declaration/proxy/CI contract; full merged config checked in CI.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

for source in flake.nix hosts/hsb0/configuration.nix hosts/hsb0/docker/compose-spec.nix modules/pharos-guarded-deploy/default.nix tests/hausnetz-hsb0-eval.nix; do
  nix-instantiate --parse "$source" >/dev/null
done

# Evaluate the actual host declarations and compose service without fetching
# inputs or realizing derivations. Stub external artifacts for restart triggers.
nix-instantiate --eval --strict --json --expr '
  let
    host = import ./hosts/hsb0/configuration.nix {
      config = {};
      pkgs.stdenv.hostPlatform.system = "fixture";
      inputs.hostdash.packages.fixture.hsb0.overrideAttrs = _: "hostdash-fixture";
      lib.mkBefore = x: x;
      lib.mkForce = x: x;
      lib.cleanSourceWith = _: "pusher-fixture";
    };
    compose = import ./hosts/hsb0/docker/compose-spec.nix;
  in {
    service = host.services.hausnetz;
    limits = host.systemd.services.hausnetz.serviceConfig;
    firewall = host.networking.firewall;
    ssh = host.programs.ssh;
    proxySource = toString host.environment.etc."hsb0-home-hausnetz.conf".source;
    frontPageSource = toString host.environment.etc."hostdash-nginx.conf".source;
    restartTriggers = map toString host.nixcfg.composeStack.extraRestartTriggers;
    home = compose.services.hsb0-home;
    hostdashStatus = host.services.hostdash.status;
  }
' | python3 -c '
import json, sys
c = json.load(sys.stdin)
s, fw, home = c["service"], c["firewall"], c["home"]
assert s["enable"] and s["listen"] == "0.0.0.0:8377"
assert s["firewallInterfaces"] == ["br-+", "docker0"]
assert s["discovery"] == {"openFirewallMdns": True, "openFirewallSsdp": True, "mdnsInterfaces": ["enp2s0f0"], "passive": True}
assert "seed" not in s and "leasesFile" not in s["discovery"] and "extraArgs" not in s and "starlink" not in s
assert fw["enable"] and 8377 not in fw["allowedTCPPorts"] and all(p not in fw["allowedUDPPorts"] for p in (5353, 1901))
assert c["limits"] == {"MemoryMax": "512M", "CPUQuota": "50%", "Nice": 10}
assert home.get("network_mode", "bridge") == "bridge"
assert home["extra_hosts"] == ["host.docker.internal:host-gateway"]
assert "/etc/hsb0-home-hausnetz.conf:/etc/nginx/hostdash-extra/hausnetz.conf:ro" in home["volumes"]
assert "/var/lib/videos:/srv/videos:ro" in home["volumes"]  # OPS-380
assert "/etc/hsb0-home-videos.conf:/etc/nginx/hostdash-extra/videos.conf:ro" in home["volumes"]
assert c["proxySource"].endswith("/hosts/hsb0/docker/hsb0-home-hausnetz.conf")
assert c["frontPageSource"].endswith("/docker/front-page-nginx.conf")
for snippet in ("front-page-nginx.conf", "hsb0-home-hausnetz.conf", "hsb0-home-inflight.conf", "hsb0-home-videos.conf"):
    assert any(t.endswith("/hosts/hsb0/docker/" + snippet) for t in c["restartTriggers"]), snippet
ssh = c["ssh"]
assert "Match host github.com localuser root" in ssh["extraConfig"]
assert "IdentityFile /root/.ssh/hausnetz_deploy" in ssh["extraConfig"]
assert "IdentitiesOnly yes" in ssh["extraConfig"]
assert ssh["extraConfig"].strip().endswith("Host *")
assert ssh["knownHosts"]["github.com"]["publicKey"] == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
status = c["hostdashStatus"]
assert status["enable"] and status["host"] == "hsb0"
assert {
    "hausnetz.service", "ncps-warmer.timer", "ib-gateway-session.timer",
    "uptime-kuma.service", "compose-hsb0-update.timer", "lg-devmode-renew.timer",
}.issubset(status["units"])
assert status["httpProbes"]["hsb0-home"] == "http://127.0.0.1:80/inflight/"
print("OPS-207 evaluated host declarations: OK")
'

python3 - <<'PY'
import copy
import json
import re
import os
import stat
import subprocess
import tempfile
from pathlib import Path

defaults = json.loads(subprocess.check_output(['nix-instantiate', '--eval', '--strict', '--json', '--expr', '''
  let
    module = host: import ./modules/pharos-guarded-deploy/default.nix {
      config.networking.hostName = host; lib.mkOption = x: x; inputs = {}; pkgs = {};
    };
    defaults = host: let opts = (module host).options.inspr.pharosGuardedDeploy; in {
      privateInputHosts = opts.privateInputHosts.default;
      canEvaluatePrivateInputs = opts.canEvaluatePrivateInputs.default;
    };
  in { hsb0 = defaults "hsb0"; hsb8 = defaults "hsb8"; }
'''], text=True))
assert defaults == {'hsb0': {'privateInputHosts': ['hsb0'], 'canEvaluatePrivateInputs': True},
                    'hsb8': {'privateInputHosts': ['hsb0'], 'canEvaluatePrivateInputs': False}}

# Exercise the actual merged-config checker offline, including negative cases
# for a global/ranged opening or an SSDP reply port on another interface.
# CI separately applies this checker to the full real module merge.
fixture = {
    'services': {'hausnetz': {
        'enable': True, 'listen': '0.0.0.0:8377', 'firewallInterfaces': ['br-+', 'docker0'],
        'seed': None, 'extraArgs': [], 'starlink': True, 'discovery': {
            'leasesFile': '/var/lib/AdGuardHome/data/leases.json', 'openFirewallMdns': True, 'mdnsInterfaces': ['enp2s0f0'],
            'openFirewallSsdp': True, 'ssdpPort': 1901, 'ssdpInterfaces': ['enp2s0f0'],
            'passive': True, 'passiveInterfaces': ['enp2s0f0'], 'webCheck': True}}},
    'networking': {'nftables': {'enable': False}, 'firewall': {
        'enable': True, 'trustedInterfaces': [], 'allowedTCPPorts': [], 'allowedTCPPortRanges': [],
        'allowedUDPPorts': [], 'allowedUDPPortRanges': [], 'interfaces': {
            'br-+': {'allowedTCPPorts': [8377]}, 'docker0': {'allowedTCPPorts': [8377]},
            'enp2s0f0': {'allowedUDPPorts': [5353, 1901]}}}},
    'systemd': {'services': {'hausnetz': {'serviceConfig': {
        'StateDirectory': 'hausnetz', 'ExecStart': '"hausnetz" "--ssdp-port" "1901" "--passive" "--passive-interfaces" "enp2s0f0"',
        'RestrictAddressFamilies': ['AF_INET', 'AF_INET6', 'AF_NETLINK', 'AF_PACKET', 'AF_UNIX'],
        'MemoryMax': '512M', 'CPUQuota': '50%', 'Nice': 10, 'SupplementaryGroups': ['hausnetz-leases']}}}},
    'environment': {'etc': {'hsb0-home-hausnetz.conf': {'source': '/hosts/hsb0/docker/hsb0-home-hausnetz.conf'}}},
    'nixcfg': {'composeStack': {'extraRestartTriggers': [
        '/hosts/hsb0/docker/hsb0-home-hausnetz.conf', '/hosts/hsb0/docker/hsb0-home-inflight.conf',
        '/hosts/hsb0/docker/hsb0-home-videos.conf']}},
}

def check_fixture(config):
    expression = 'import ./tests/hausnetz-hsb0-eval.nix { config = builtins.fromJSON ' + json.dumps(json.dumps(config)) + "; lib = {" + '''
      hasInfix = needle: text: builtins.replaceStrings [ needle ] [ "" ] text != text;
      hasSuffix = suffix: text: let
        offset = builtins.stringLength text - builtins.stringLength suffix;
      in offset >= 0 && builtins.substring offset (builtins.stringLength suffix) text == suffix;
    }; }
'''
    return json.loads(subprocess.check_output(['nix-instantiate', '--eval', '--strict', '--json', '--expr', expression], text=True))

checks = check_fixture(fixture)
assert all(checks.values()), checks
for path, value, failed_check in (
    (('networking', 'firewall', 'allowedUDPPorts'), [1901], 'noGlobalSsdp'),
    (('networking', 'firewall', 'allowedUDPPortRanges'), [{'from': 1900, 'to': 1902}], 'noGlobalSsdp'),
    (('networking', 'firewall', 'interfaces', 'docker0', 'allowedUDPPorts'), [1901], 'noOtherInterfaceSsdp'),
    (('networking', 'firewall', 'interfaces', 'docker0', 'allowedUDPPortRanges'), [{'from': 1900, 'to': 1902}], 'noOtherInterfaceSsdp'),
    (('networking', 'firewall', 'interfaces', 'enp2s0f0', 'allowedUDPPorts'), [5353], 'ssdpReachable'),
    (('services', 'hausnetz', 'discovery', 'ssdpInterfaces'), ['docker0'], 'ssdpLanOnly'),
    (('services', 'hausnetz', 'discovery', 'ssdpPort'), 1900, 'ssdpPort'),
    (('services', 'hausnetz', 'discovery', 'openFirewallSsdp'), False, 'ssdpEnabled'),
    (('systemd', 'services', 'hausnetz', 'serviceConfig', 'ExecStart'), '"hausnetz"', 'ssdpArgument'),
    (('systemd', 'services', 'hausnetz', 'serviceConfig', 'RestrictAddressFamilies'), ['AF_INET', 'AF_UNIX'], 'netlinkAllowed'),
    (('services', 'hausnetz', 'discovery', 'passive'), False, 'passiveEnabled'),
    (('services', 'hausnetz', 'discovery', 'webCheck'), False, 'webCheckAllowed'),
    (('systemd', 'services', 'hausnetz', 'serviceConfig', 'ExecStart'), '"hausnetz" "--ssdp-port" "1901" "--web-check=false" "--passive" "--passive-interfaces" "enp2s0f0"', 'noWebCheckFlag'),
    (('services', 'hausnetz', 'starlink'), False, 'starlinkAllowed'),
    (('systemd', 'services', 'hausnetz', 'serviceConfig', 'ExecStart'), '"hausnetz" "--ssdp-port" "1901" "--starlink=false" "--passive" "--passive-interfaces" "enp2s0f0"', 'noStarlinkFlag'),
    (('services', 'hausnetz', 'discovery', 'leasesFile'), None, 'leasesFromAdguard'),
    (('systemd', 'services', 'hausnetz', 'serviceConfig', 'SupplementaryGroups'), [], 'leasesCopyGroupOnly'),
    (('services', 'hausnetz', 'discovery', 'passiveInterfaces'), ['enp2s0f0', 'docker0'], 'passiveLanOnly'),
    (('systemd', 'services', 'hausnetz', 'serviceConfig', 'ExecStart'), '"hausnetz" "--ssdp-port" "1901"', 'passiveArgument'),
    (('systemd', 'services', 'hausnetz', 'serviceConfig', 'RestrictAddressFamilies'), ['AF_INET', 'AF_NETLINK', 'AF_UNIX'], 'packetAllowed'),
    (('nixcfg', 'composeStack', 'extraRestartTriggers'), ['/hosts/hsb0/docker/hsb0-home-hausnetz.conf'], 'proxyRestartTriggers'),
    (('nixcfg', 'composeStack', 'extraRestartTriggers'), ['/hosts/hsb0/docker/hsb0-home-inflight.conf'], 'proxyRestartTriggers'),
    (('nixcfg', 'composeStack', 'extraRestartTriggers'), ['/hosts/hsb0/docker/hsb0-home-hausnetz.conf', '/hosts/hsb0/docker/hsb0-home-inflight.conf'], 'proxyRestartTriggers'),
):
    changed = copy.deepcopy(fixture)
    node = changed
    for key in path[:-1]:
        node = node[key]
    node[path[-1]] = value
    assert check_fixture(changed)[failed_check] is False, failed_check

proxy = Path('hosts/hsb0/docker/hsb0-home-hausnetz.conf').read_text()
redirect = re.search(r'location = /ops\s*\{([^}]+)\}', proxy)[1]
legacy = re.search(r'location /ops/\s*\{([^}]+)\}', proxy)[1]
app = re.search(r'location /\s*\{([^}]+)\}', proxy)[1]
archive = re.search(r'location = /api/import\s*\{([^}]+)\}', proxy)[1]
for location in (redirect, legacy, app, archive):
    assert re.search(r'allow 192\.168\.1\.0/24;\s*deny all;', location)
# Redirect only after access checks; internally rewrite writes before returning 301.
for location in (redirect, legacy):
    assert not re.search(r'^\s*return\s', location, re.M)
    assert 'try_files "" @hausnetz_ops_redirect;' in location
assert 'client_max_body_size 257m;' in legacy
assert 'if ($request_method !~ ^(GET|HEAD)$)' in proxy
assert 'rewrite ^/ops(?:/(.*))?$ /$1 last;' in proxy
assert 'if ($request_uri ~ "^/ops(?:/+)?(.*)$")' in proxy
assert 'return 301 /$1;' in proxy
assert 'client_max_body_size 13m;' in app
assert 'client_max_body_size 257m;' in archive
assert 'proxy_pass http://host.docker.internal:8377/;' in app
assert 'proxy_pass http://host.docker.internal:8377/api/import;' in archive
settings = lambda location: [line.strip() for line in location.splitlines() if line.strip()]
assert settings(archive.replace('257m;', '13m;').replace(':8377/api/import;', ':8377/;')) == settings(app)
for location in (app, archive):
    for directive in ('proxy_buffering off;', 'proxy_http_version 1.1;',
                      'proxy_set_header Connection "";', 'proxy_read_timeout 1h;',
                      'proxy_cache off;', 'proxy_hide_header Cache-Control;',
                      'add_header Cache-Control "no-store" always;'):
        assert directive in location, directive
vhost_path, = Path('hosts').glob('*/docker/front-page-nginx.conf')
vhost = vhost_path.read_text()
for route in ('/hostdash/', '/hostdash/status/', '/status/', '= /config.js', '= /manifest.json'):
    assert 'location ' + route in vhost
assert 'location / {' not in vhost  # only the included app snippet owns the root
assert 'include /etc/nginx/hostdash-extra/*.conf;' in vhost
assert 'include /etc/nginx/hostdash-extra/*.conf;' in Path('modules/files/hostdash-nginx.conf').read_text()

pin = 'b420e1123d40bcd8e111aa7857d0a0a87cf023b2'  # HNET pin 41 (v261025171939.0.0); repo in inspr-at
assert f'git+ssh://git@github.com/inspr-at/hausnetz?rev={pin}' in Path('flake.nix').read_text()
lock = json.loads(Path('flake.lock').read_text())
assert lock['nodes'][lock['root']]['inputs']['hausnetz'] == 'hausnetz'
node = lock['nodes']['hausnetz']
assert node['inputs'] == {'nixpkgs': ['nixpkgs']}
for source in ('locked', 'original'):
    assert node[source]['type'] == 'git' and node[source]['rev'] == pin
    assert node[source]['url'] == 'ssh://git@github.com/inspr-at/hausnetz'
assert node['locked']['narHash'] == 'sha256-h+76+Xz/Tti/TIpXweAWLfOgETDaevG/iNVQ21dd1KE='
assert node['locked']['lastModified'] == 1792951557
imports = [p for p in Path('hosts').rglob('*.nix') if 'inputs.hausnetz.nixosModules.default' in p.read_text()]
assert imports == [Path('hosts/hsb0/configuration.nix')], imports

workflows = ('check', 'pharos-system-update', 'pharos-host-removal', 'pharos-host-settings', 'update-flake-lock', 'pharos-release-rollout')
for name in workflows:
    text = Path(f'.github/workflows/{name}.yml').read_text()
    assert 'GIT_CONFIG_' not in text, name
    assert 'HAUSNETZ_DEPLOY_KEY' not in text.split('jobs:', 1)[0], name
    uses = list(re.finditer(r'uses: \./\.github/actions/hausnetz-input\n\s+with:\n\s+deploy-key: \$\{\{ secrets\.HAUSNETZ_DEPLOY_KEY \}\}', text))
    assert len(uses) == (2 if name == 'check' else 0 if name in ('update-flake-lock', 'pharos-release-rollout') else 1), name
    assert text.count('secrets.HAUSNETZ_DEPLOY_KEY') == len(uses), name
    if name == 'check':
        jobs = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', text.split('jobs:', 1)[1], re.M | re.S))
        assert 'GH_TOKEN_FOR_UPDATES' not in text
        assert "if: matrix.host == 'hsb0'\n        uses: ./.github/actions/hausnetz-input" in jobs['check']
        private_shard, = [name for name, job in jobs.items()
                          if name.startswith('pharos-contracts-') and 'uses: ./.github/actions/hausnetz-input' in job]
        assert "if: steps.pin.outputs.pin_only != 'true'\n        uses: ./.github/actions/hausnetz-input" in jobs[private_shard]
        assert all('hausnetz-input' not in job for name, job in jobs.items() if name not in ('check', private_shard))
    if name == 'pharos-host-settings':
        assert "if: inputs.host == 'hsb0'\n        uses: ./.github/actions/hausnetz-input" in text

# Only T38 gets the SSH override; later hsb0 evals reuse its stored locked source.
# The private key is cleaned up in the next step even when T38 fails.
steps = re.split(r'^      - ', jobs[private_shard], flags=re.M)[1:]
key_index, = [i for i, step in enumerate(steps) if 'uses: ./.github/actions/hausnetz-input' in step]
assert 'run: tests/T38-pharos-deployment-evidence.sh' in steps[key_index + 1]
assert 'id: hausnetz-input' in steps[key_index]
assert 'persist-ssh-command: "false"' in steps[key_index]
assert 'GIT_SSH_COMMAND: ${{ steps.hausnetz-input.outputs.git-ssh-command }}' in steps[key_index + 1]
assert all('GIT_SSH_COMMAND' not in step for step in steps[key_index + 2:])
cleanup = steps[key_index + 2]
assert 'name: Clean up private hsb0 input access (OPS-355)' in cleanup
assert "if: always() && steps.pin.outputs.pin_only != 'true'\n" in cleanup
cleanup_script = '\n'.join(line[10:] for line in cleanup.split('        run: |\n', 1)[1].splitlines())
assert any('run: bash tests/T14-pharos-system-update.sh' in step for step in steps)

# Execute the real composite action script with a non-secret fixture. No SSH
# connection is made; prove file modes, host pinning and absence from logs/env.
action = Path('.github/actions/hausnetz-input/action.yml').read_text()
script = '\n'.join(line[8:] for line in action.split('      run: |\n', 1)[1].splitlines())
assert 'HAUSNETZ_DEPLOY_KEY: ${{ inputs.deploy-key }}' in action
assert 'ssh-keyscan ' not in script
with tempfile.TemporaryDirectory(prefix='ops207-ci-') as tmp:
    output = Path(tmp, 'github-env')
    output.write_text('')
    step_output = Path(tmp, 'github-output')
    fixture_key = 'OPS-207 non-secret deploy-key fixture'
    child_env = dict(os.environ, RUNNER_TEMP=tmp, GITHUB_ENV=str(output), GITHUB_OUTPUT=str(step_output),
                     HAUSNETZ_DEPLOY_KEY=fixture_key, PERSIST_SSH_COMMAND='true')
    result = subprocess.run(['bash', '-c', script], env=child_env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert fixture_key not in result.stdout + result.stderr + output.read_text() + step_output.read_text()
    ssh_dir, = Path(tmp).glob('hausnetz-ssh.*')
    assert stat.S_IMODE(ssh_dir.stat().st_mode) == 0o700
    assert stat.S_IMODE((ssh_dir / 'key').stat().st_mode) == 0o600
    assert (ssh_dir / 'key').read_text() == fixture_key + '\n'
    assert (ssh_dir / 'known_hosts').read_text() == 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n'
    assert all(option in output.read_text() for option in ('-F /dev/null', 'IdentitiesOnly=yes', 'BatchMode=yes', 'UserKnownHostsFile=', 'GlobalKnownHostsFile=/dev/null', 'StrictHostKeyChecking=yes'))
    assert step_output.read_text().removeprefix('git-ssh-command=') == output.read_text().removeprefix('GIT_SSH_COMMAND=')
    child_env['HAUSNETZ_DEPLOY_KEY'] = ''
    result = subprocess.run(['bash', '-c', script], env=child_env, capture_output=True, text=True)
    assert result.returncode != 0 and 'HAUSNETZ_DEPLOY_KEY is required' in result.stderr
    unrelated = Path(tmp, 'unrelated-job-file')
    unrelated.write_text('keep')
    for _ in range(2):  # Cleanup also tolerates a skipped or failed key step.
        result = subprocess.run(['bash', '-c', cleanup_script], env=child_env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert not list(Path(tmp).glob('hausnetz-ssh.*'))
        assert unrelated.read_text() == 'keep'

    # T38-only mode never exports the override to the job environment, so
    # subsequent steps truly have it unset rather than set to an empty string.
    output.write_text('')
    step_output.write_text('')
    child_env.update(HAUSNETZ_DEPLOY_KEY=fixture_key, PERSIST_SSH_COMMAND='false')
    result = subprocess.run(['bash', '-c', script], env=child_env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert output.read_text() == ''
    assert step_output.read_text().startswith('git-ssh-command=ssh ')
    assert fixture_key not in result.stdout + result.stderr + step_output.read_text()
    result = subprocess.run(['bash', '-c', cleanup_script], env=child_env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert not list(Path(tmp).glob('hausnetz-ssh.*'))
    assert output.read_text() == ''

# Run the declared warmer against a fake Nix. Fail hsb0 while allowing later
# hosts to warm, and prove that a dry-run failure cannot look already cached.
warmer = subprocess.check_output(['nix-instantiate', '--eval', '--strict', '--json', '--expr', '''
  (import ./hosts/hsb0/configuration.nix {
    pkgs = {}; config = {}; inputs = {}; lib.mkBefore = x: x;
  }).systemd.services.ncps-warmer.script
'''], text=True)
warmer = json.loads(warmer)
with tempfile.TemporaryDirectory(prefix='ops207-warmer-') as tmp:
    root = Path(tmp)
    (root / 'git').write_text('#!/usr/bin/env bash\nexit 0\n')
    (root / 'nix').write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$WARMER_CALLS"
if [[ "$*" == *nixosConfigurations.hsb0* && "$FAIL_HSB0" == 1 ]]; then
  echo 'fixture: private input unavailable' >&2
  exit 1
fi
if [[ "$WARMER_FETCH" == 1 ]]; then
  printf 'these paths will be fetched:\\n  /nix/store/fixture-substitute\\n' >&2
fi
''')
    (root / 'nix-store').write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$WARMER_REALISED"
''')
    for command in ('git', 'nix', 'nix-store'):
        (root / command).chmod(0o700)
    # Preserve the real declared script, replacing only its checkout directory.
    script = warmer.replace('REPO="/home/mba/Code/nixcfg"', f'REPO="{root}"')
    child_env = dict(os.environ, PATH=f'{root}:' + os.environ['PATH'], WARMER_CALLS=str(root / 'calls'), WARMER_REALISED=str(root / 'realised'))
    for fail, fetch in (('1', '0'), ('0', '0'), ('0', '1')):
        child_env.update(FAIL_HSB0=fail, WARMER_FETCH=fetch)
        result = subprocess.run(['bash', '-c', script], env=child_env, capture_output=True, text=True)
        if fail == '1':
            assert result.returncode != 0
            assert 'warmer: hsb0 — evaluation/dry-run FAILED' in result.stderr
            assert 'warmer: hsb0 — nothing to fetch' not in result.stdout
            assert 'warmer: mbp2607' in result.stdout and 'warmer: done' not in result.stdout
        else:
            assert result.returncode == 0, result.stderr
            assert 'warmer: done' in result.stdout
            assert ('warmer: hsb0 — warmed 1 paths' if fetch == '1' else 'warmer: hsb0 — nothing to fetch (already cached)') in result.stdout, result.stdout
    assert '/nix/store/fixture-substitute' in (root / 'realised').read_text()

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
step = ci.split('      - name: Verify hausnetz in the full hsb0 configuration (OPS-207)\n', 1)[1].split('  # ===', 1)[0]
command = '\n'.join(line[10:] for line in step.split('        run: |\n', 1)[1].splitlines() if line.strip())
assert command in Path('hosts/hsb0/docs/RUNBOOK.md').read_text(), 'runbook must carry the exact CI command'
print('OPS-207 proxy and CI contracts: OK')
PY
