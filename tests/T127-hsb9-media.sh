#!/usr/bin/env bash
# OPS-729/OPS-739/OPS-746: app/UI, status/cache contracts and real nginx parsing.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Eval-free HostDash wiring contract; no NixOS configuration is evaluated.
grep -Fq '    ../../modules/hostdash-status.nix' "$repo/hosts/hsb9/configuration.nix"
grep -Fq '    host = "hsb9";' "$repo/hosts/hsb9/configuration.nix"
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

def eval_spec(path):
    return json.loads(subprocess.check_output([
        "nix-instantiate", "--eval", "--strict", "--json", str(path),
    ], text=True))

spec = eval_spec(repo / "hosts/hsb9/docker/compose-spec.nix")
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
assert [mount for mount in home["volumes"] if mount.startswith("/var/lib/hostdash-status:")] == [
    "/var/lib/hostdash-status:/srv/hostdash-status:ro"
]
assert "/etc/hsb9-home.conf:/etc/nginx/conf.d/default.conf:ro" in home["volumes"]
assert "/srv/media/fernsehaufnahmen:/data:ro" in home["volumes"]
for name, service in services.items():
    if "restic" in name:
        assert all("/srv/media" not in mount for mount in service["volumes"])
host = (repo / "hosts/hsb9/configuration.nix").read_text()
for path in ("/srv/media/fernsehaufnahmen", "/srv/media/fernsehaufnahmen/.trash",
             "/srv/media/fernsehaufnahmen/.thumbs"):
    assert f'"d {path} 0750 10429 101 -"' in host, path
assert 'environment.etc."hsb9-media".source = ./docker/media;' in host
assert 'environment.etc."hsb9-home.conf".source = ./docker/home.conf;' in host
assert "./docker/media" in host.split("extraRestartTriggers = [", 1)[1].split("];", 1)[0]
assert re.findall(r'"([^"]+)"', host.split("postRecreate = [", 1)[1].split("];", 1)[0]) == [
    "hsb9-home"
]
status = re.search(r"services\.hostdash\.status = \{(.*?)\n  \};", host, re.DOTALL)
assert status, "hsb9 status configuration missing"
for directive in ('enable = true;', 'host = "hsb9";', '"compose-hsb9-update.timer"',
                  '"docker.service"', '"sshd.service"',
                  'homeassistant = "http://127.0.0.1:8123/";',
                  'hsb9-media = "http://127.0.0.1/fernsehen/healthz";'):
    assert directive in status.group(1), directive
assert "mqttEnvFile" not in status.group(1) and "mqttExtras" not in status.group(1)
# Each shipped app asset must change media's compose hash; nginx-only changes
# must leave it alone so a status/cache fix does not interrupt playback.
assert any(re.fullmatch(r"nixcfg\.media-source-sha256=[a-f0-9]{64}", label)
           for label in media["labels"])
with tempfile.TemporaryDirectory(prefix="t127-compose-") as temporary:
    fixture = Path(temporary)
    shutil.copy(repo / "hosts/hsb9/docker/compose-spec.nix", fixture)
    shutil.copy(repo / "hosts/hsb9/docker/home.conf", fixture)
    (fixture / "media").mkdir()
    for asset in ("app.py", "app.js", "app.css", "index.html"):
        shutil.copy(repo / "hosts/hsb9/docker/media" / asset, fixture / "media")
    baseline = eval_spec(fixture / "compose-spec.nix")
    assert baseline == spec
    with (fixture / "home.conf").open("a") as config:
        config.write("\n# nginx-only change\n")
    assert eval_spec(fixture / "compose-spec.nix") == baseline
    for asset in ("app.py", "app.js", "app.css", "index.html"):
        path = fixture / "media" / asset
        original = path.read_bytes()
        path.write_bytes(original + b"\n")
        changed = eval_spec(fixture / "compose-spec.nix")
        assert changed["services"]["hsb9-media"]["labels"] != media["labels"], asset
        changed["services"]["hsb9-media"]["labels"] = media["labels"]
        assert changed == baseline, asset
        path.write_bytes(original)
nginx = (repo / "hosts/hsb9/docker/home.conf").read_text()

def location(declaration):
    match = re.search(r"^    " + re.escape(declaration) + r" \{\n(.*?)^    \}\n",
                      nginx, re.MULTILINE | re.DOTALL)
    assert match, f"missing nginx {declaration}"
    return match.group(1)

# These are sibling locations: no server-level header or validator settings may
# leak HostDash's policy into the media proxy, video or thumbnail responses.
assert not re.search(r"^    (?:add_header|etag|if_modified_since)\s", nginx, re.MULTILINE)
root_block = location("location /")
for directive in ("try_files $uri $uri/ =404;", "etag off;", "if_modified_since off;",
                  'add_header Cache-Control "no-store" always;'):
    assert directive in root_block, directive
status_block = location("location /status/")
for directive in ("alias /srv/hostdash-status/;", "autoindex off;",
                  'add_header Cache-Control "no-store" always;', "default_type application/json;"):
    assert directive in status_block, directive
for directive in ("root /usr/share/nginx/html;", "try_files $uri $uri/ =404;", "alias /data/$1;",
                  "disable_symlinks on;", "autoindex off;", "client_max_body_size 0;",
                  "proxy_request_buffering off;", "proxy_set_header Host $http_host;",
                  "resolver 127.0.0.11 valid=10s ipv6=off;", "proxy_read_timeout 3600s;",
                  "proxy_send_timeout 3600s;", "proxy_intercept_errors on;",
                  "location /fernsehen/video/ {\n        return 404;"):
    assert directive in nginx, directive
# Preserve video hardening and its own cache/security headers.
video_block = location(r"location ~ ^/fernsehen/video/(?!\.)([^/]+\.(?i:mp4|m4v|mov))$")
for directive in ("alias /data/$1;", "disable_symlinks on;", "autoindex off;",
                  "limit_except GET { deny all; }", "types { video/mp4 mp4 m4v; video/quicktime mov; }",
                  "default_type application/octet-stream;", "access_log off;",
                  "add_header X-Content-Type-Options nosniff always;",
                  'add_header Cache-Control "private, no-store" always;'):
    assert directive in video_block, directive
# OPS-739: sidecar thumbnails are flat, read-only, GET/HEAD-only, symlink-free files
# from /data/.thumbs; every other /fernsehen/thumb/ path is a 404 (never the app).
thumb = re.search(r"\n    location ~ \^/fernsehen/thumb/\(\?!\\\.\)\(\[\^/\]\+\\\.jpg\)\$ \{\n(.*?)\n    \}\n",
                  nginx, re.DOTALL)
assert thumb, "thumbnail location missing or its pattern changed"
thumb_block = thumb.group(1)
for directive in ("alias /data/.thumbs/$1;", "disable_symlinks on;", "autoindex off;",
                  "limit_except GET { deny all; }", "types { image/jpeg jpg; }",
                  "add_header X-Content-Type-Options nosniff always;", "access_log off;"):
    assert directive in thumb_block, directive
assert 'add_header Cache-Control "private, max-age=86400" always;' in thumb_block
assert "proxy_pass" not in thumb_block and "client_max_body_size" not in thumb_block
assert "location /fernsehen/thumb/ {\n        return 404;" in nginx
assert nginx.index("location ~ ^/fernsehen/thumb/") < nginx.index("location /fernsehen/ {")
for media_block in (video_block, thumb_block, location("location /fernsehen/")):
    assert "etag off;" not in media_block and "if_modified_since off;" not in media_block
    assert 'add_header Cache-Control "no-store" always;' not in media_block
# Preserve app JSON 503 errors while retaining nginx's offline lookup/connect/timeout page.
assert re.findall(r"^\s*error_page\s+([^;]+);", nginx, re.MULTILINE) == [
    "502 504 /fernsehen-offline.html"
]
js = (repo / "hosts/hsb9/docker/media/app.js").read_text()
assert "innerHTML" not in js and "insertAdjacentHTML" not in js and "outerHTML" not in js
assert "eval(" not in js and "new Function" not in js
# OPS-739: friendly native <dialog> confirmations replace window.confirm.
assert "window.confirm(" not in js and "showModal()" in js
assert 'const LANG_KEY = "hostdash.lang";' in js
assert 'const PROGRESS_KEY = "hsb9-media.progress";' in js
for asset in ("app.js", "app.css", "index.html"):
    text = (repo / "hosts/hsb9/docker/media" / asset).read_text()
    assert not re.search(r"(?:https?:)?//(?!www\.w3\.org/2000/svg)[a-z0-9.-]+\.[a-z]{2,}", text), asset
    assert "@import" not in text and "@font-face" not in text, asset
csp = re.search(r'"Content-Security-Policy", "([^)]*?)"\)', (repo / "hosts/hsb9/docker/media/app.py").read_text().replace('"\n                         "', ""))
assert csp, "CSP header not found"
policy = csp.group(1)
assert "media-src 'self' blob:;" in policy and policy.count("blob:") == 1, policy
assert "unsafe-inline" not in policy and "unsafe-eval" not in policy, policy
workflow = (repo / ".github/workflows/check.yml").read_text()
assert workflow.count('run: nix-shell -p python3 nginx nodejs --run "bash tests/T127-hsb9-media.sh"') == 1
print("T127 hsb9 media: app/UI tests and container/routing contracts passed", flush=True)
# Parse the authored server block with a real nginx, without starting a server,
# privileged ports, Docker DNS, production data or a writable HostDash tree.
with tempfile.TemporaryDirectory(prefix="t127-nginx-") as temporary:
    prefix = Path(temporary)
    port = 49179  # Fixed high port; nginx reports a collision below if occupied.
    listen_line = re.compile(r"^[ \t]*listen[ \t]+[^;\n]+;[ \t]*\n", re.MULTILINE)
    original_listens = listen_line.findall(nginx)
    assert [line.strip() for line in original_listens] == [
        "listen 80;", "listen [::]:80;",
    ], "update the nginx test's listener rewrite for the real server block"
    # Use IPv4 loopback only so Linux CI does not require IPv6 support or :80.
    test_listen = f"    listen 127.0.0.1:{port};\n"
    copied_nginx = nginx.replace(original_listens[0], test_listen, 1).replace(
        original_listens[1], "", 1)
    server = prefix / "home.conf"
    server.write_text(copied_nginx)
    copied_nginx = server.read_text()
    assert copied_nginx != nginx, "nginx test listener rewrite did not happen"
    assert listen_line.findall(copied_nginx) == [test_listen]
    assert listen_line.sub("", copied_nginx) == listen_line.sub("", nginx), (
        "nginx test copy must differ from the real config only in listen lines"
    )
    wrapper = prefix / "nginx.conf"
    wrapper.write_text('error_log stderr;\npid "' + str(prefix / "nginx.pid") + '";\n'
                       'events {}\nhttp {\naccess_log off;\n'
                       + ''.join(f'{kind}_temp_path "{prefix / kind}";\n'
                                 for kind in ("client_body", "proxy", "fastcgi", "uwsgi", "scgi"))
                       + 'include "' + str(server) + '";\n}\n')
    command = ["nginx", "-t", "-e", str(prefix / "error.log"),
               "-p", str(prefix) + "/", "-c", str(wrapper)]
    if shutil.which("nginx") is None:
        command = ["nix-shell", "-p", "nginx", "--run", shlex.join(command)]
    result = subprocess.run(command)
    if result.returncode:
        raise SystemExit("T127 nginx test failed; check diagnostics above and ensure "
                         f"loopback port 127.0.0.1:{port} is free")
print("T127 hsb9 media: real nginx configuration test passed")
PY
