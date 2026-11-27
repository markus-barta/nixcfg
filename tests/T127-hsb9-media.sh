#!/usr/bin/env bash
# OPS-729: offline app/UI tests, host isolation and real nginx config parsing.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B -m unittest discover -s "$repo/hosts/hsb9/docker/media" -p 'test_*.py' -v
node --test "$repo/tests/hsb9-media-ui.cjs"
python3 -B - "$repo" <<'PY'
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
spec = json.loads(subprocess.check_output([
    "nix-instantiate", "--eval", "--strict", "--json",
    str(repo / "hosts/hsb9/docker/compose-spec.nix"),
], text=True))
services = spec["services"]
media = services["hsb9-media"]
assert re.fullmatch(r"python:3\.13-alpine3\.23(?:@sha256:[a-f0-9]{64})?", media["image"])
assert media["init"] is True
assert media["user"] == "10429:101"
assert media["read_only"] is True
assert media["cap_drop"] == ["ALL"]
assert media["security_opt"] == ["no-new-privileges:true"]
assert media["restart"] == "unless-stopped"
assert media["tmpfs"] == ["/tmp:rw,noexec,nosuid,nodev,size=32m,mode=1777"]
assert "ports" not in media and "network_mode" not in media
assert media["volumes"] == ["/etc/hsb9-media:/app:ro", "/srv/media/fernsehaufnahmen:/data:rw"]
assert media["command"] == ["python3", "-B", "/app/app.py"]
assert "com.centurylinklabs.watchtower.scope=weekly" in media["labels"]
home = services["hsb9-home"]
assert "depends_on" not in home
assert home["ports"] == ["80:80"]
assert "/etc/hostdash/hsb9/share/hostdash-hsb9:/usr/share/nginx/html:ro" in home["volumes"]
assert "/etc/hsb9-home.conf:/etc/nginx/conf.d/default.conf:ro" in home["volumes"]
assert "/srv/media/fernsehaufnahmen:/data:ro" in home["volumes"]
for name, service in services.items():
    if "restic" in name:
        assert all("/srv/media" not in mount for mount in service["volumes"])
host = (repo / "hosts/hsb9/configuration.nix").read_text()
for path in ("/srv/media/fernsehaufnahmen", "/srv/media/fernsehaufnahmen/.trash"):
    assert f'"d {path} 0750 10429 101 -"' in host
assert 'environment.etc."hsb9-media".source = ./docker/media;' in host
assert 'environment.etc."hsb9-home.conf".source = ./docker/home.conf;' in host
assert "./docker/media" in host.split("extraRestartTriggers = [", 1)[1].split("];", 1)[0]
assert '"hsb9-media"' in host.split("postRecreate = [", 1)[1].split("];", 1)[0]
nginx = (repo / "hosts/hsb9/docker/home.conf").read_text()
for directive in ("root /usr/share/nginx/html;", "try_files $uri $uri/ =404;", "alias /data/$1;",
                  "disable_symlinks on;", "autoindex off;", "client_max_body_size 0;",
                  "proxy_request_buffering off;", "proxy_set_header Host $http_host;",
                  "resolver 127.0.0.11 valid=10s ipv6=off;", "proxy_read_timeout 3600s;",
                  "proxy_send_timeout 3600s;", "proxy_intercept_errors on;",
                  "location /fernsehen/video/ {\n        return 404;"):
    assert directive in nginx, directive
# Preserve app JSON 503 errors while retaining nginx's offline lookup/connect/timeout page.
assert re.findall(r"^\s*error_page\s+([^;]+);", nginx, re.MULTILINE) == [
    "502 504 /fernsehen-offline.html"
]
js = (repo / "hosts/hsb9/docker/media/app.js").read_text()
assert "innerHTML" not in js and "insertAdjacentHTML" not in js
assert "window.confirm(" in js
workflow = (repo / ".github/workflows/check.yml").read_text()
assert workflow.count('run: nix-shell -p python3 nginx nodejs --run "bash tests/T127-hsb9-media.sh"') == 1
print("T127 hsb9 media: app/UI tests and container/routing contracts passed", flush=True)
# Parse the authored server block with a real nginx, without starting a server,
# privileged ports, Docker DNS, production data or a writable HostDash tree.
with tempfile.TemporaryDirectory(prefix="t127-nginx-") as temporary:
    prefix = Path(temporary)
    wrapper = prefix / "nginx.conf"
    wrapper.write_text('error_log stderr;\npid "' + str(prefix / "nginx.pid") + '";\n'
                       'events {}\nhttp {\naccess_log off;\n'
                       + ''.join(f'{kind}_temp_path "{prefix / kind}";\n'
                                 for kind in ("client_body", "proxy", "fastcgi", "uwsgi", "scgi"))
                       + 'include "' + str(repo / "hosts/hsb9/docker/home.conf") + '";\n}\n')
    command = ["nginx", "-t", "-p", str(prefix) + "/", "-c", str(wrapper)]
    if shutil.which("nginx") is None:
        command = ["nix-shell", "-p", "nginx", "--run", shlex.join(command)]
    subprocess.run(command, check=True)
print("T127 hsb9 media: real nginx configuration test passed")
PY
