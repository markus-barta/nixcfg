# nixcfg — Agent Doctrine Overlay

_This file is the THIN OVERLAY for **nixcfg-specific** rules. Universal rules + Markus profile live upstream in [inspr-modules](https://github.com/markus-barta/inspr-modules); the kernel (auto-loaded) carries the always-on subset, and slash commands (`/dev /secrets /nix /ops /ppm /style /incident /inspr`) load deeper context on demand._

## Where to find what (post-Phase-6, 2026-05-15)

| Need                                           | Where it lives                                                                           |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Auto-loaded hard safety + identity + router    | `doctrine/docs/AGENTS-KERNEL.md` (kernel)                                                |
| Per-domain depth (secrets, nix, dev, ops, ppm) | `doctrine/docs/AGENTS-DOMAIN-*.md` (load via `/secrets`, `/nix`, `/dev`, `/ops`, `/ppm`) |
| Markus full profile                            | `doctrine/docs/AGENTS-PROFILE-MARKUS.md` (load via `/style`)                             |
| Per-role overlays                              | `doctrine/docs/AGENTS-AGENT-*.md` (loaded by slash commands)                             |
| Exhaustive universal-rules reference           | `doctrine/docs/AGENTS-CORE.md` (rarely needed; `/style` etc. cover the practical subset) |
| **This file**                                  | nixcfg-specific delta only                                                               |

_Phase 4 synthesized 55 nixcfg-specific rules from sources on 2026-05-14. Phase 6 (2026-05-15) made this file the only per-repo file auto-loaded alongside the kernel._

<!-- KERNEL-MIRROR-BEGIN — auto-mirrored irreducible subset of inspr-modules/docs/AGENTS-KERNEL.md (INSPR-191). Edit upstream + bump submodule, then re-mirror here. For tools that read AGENTS.md but not the kernel via CLAUDE.md @-ref (Cursor, Aider, OpenCode, Codex CLI, Continue, etc.). -->

## Universal must-knows (kernel mirror)

- **Identity**: Markus Barta, `markus@barta.com`, `markus-barta` on GitHub. Never invent placeholders.
- **Workspace**: `~/Code/`. Repos under `github.com/markus-barta/<name>`. Third-party clones go to `~/Projects/3rdparty/`.
- **Time awareness**: Run `date` before any time-of-day-coded greeting/farewell ("good evening", 🌙 / ☀️). Knowing the date alone tells you nothing about morning/night. Prefer time-neutral closings ("cheers", "until next time") if a check would be disruptive.
- **Style**: telegraph, dense, low-fluff. **Long** answers: TL;DR at start AND end. **Short**: TL;DR at end only. **Very short**: omit TL;DR.
- **Pacing**: ONE STEP AT A TIME for interactive procedures (agenix, ssh, paimos auth, rotation flows). Wait for explicit "done" before next step. Never dump 5- or 10-step playbooks.
- **Secrets**: NEVER `cat / Read / head / tail / less / bat / xxd / od / sed / grep` files in `~/.inspr/secrets/agents/`, `~/Secrets/`, `~/.ssh/<not-pub>`, `/run/agenix/`, `/run/secrets/`, or any `*.env` / `*.age` / `*.gpg` / `id_*` / `*_rsa` / `*_ed25519`. Source via `( set -a; source FILE; cmd; set +a )`. NEVER run `direnv export`, `direnv status`, `set`, `declare -x/-p`, `compgen -e`, `export -p`, bare `env` / `printenv`, `docker exec ... cat env`, `kubectl describe configmap` after env expansion. If a secret appears in output: **STOP**, name affected vars (not values), rotate before continuing.
- **Git**: never `reset --hard` / `clean -f` / `restore .` / `branch -D` / `rm` unless asked. Never `--force` push main. Never `--no-verify` / `--no-gpg-sign` / `--amend` unless asked. Never commit secrets (passwords, API keys, .env with real creds, decrypted .age content). `git diff` + `git status` before every commit.
- **Files & ops**: use `trash` not `rm -rf`. Don't delete or rename unexpected items — STOP and ask. Touch encrypted files only with explicit permission. **NEVER build NixOS configs on macOS** (build remotely via ssh; macOS HM CAN build locally). Never create new `.md` files unless asked — **knowledge (architecture, design, positioning, playbooks, field notes, durable how-tos) goes in PPM Knowledge entries, not local docs** (see `/ppm`). Stays local: README, AGENTS.md/CLAUDE.md + doctrine, RUNBOOK.md, CHANGELOG.md, RESUMING-\*, LICENSE, code comments.
- **Naming**: **BYTEPOETS** always all-caps (registered wordmark). **`.cm`** TLD intentional, never auto-correct to `.com`. **INSPR** is the umbrella; Paimos / FleetCom / future tools are inside it.

For full kernel + domain packs: see [`inspr-modules/docs/AGENTS-KERNEL.md`](https://github.com/markus-barta/inspr-modules/blob/main/docs/AGENTS-KERNEL.md). Claude Code agents: run `/inspr` for the TL;DR map of slash commands.

<!-- KERNEL-MIRROR-END -->

---

## Topic: security/git-commits

- 🔴 **HARD** | `never` | MAC addresses may only appear in encrypted .age files
  _<sub>src: ~/Code/nixcfg/+agents/rules/SYSOP.md L309</sub>_
  <!-- rule_ids: SYSOP.md:L309:mac-addresses-only-encrypted | cluster: — -->

- 🔴 **HARD** | `never` | Never commit PII (family names, personal emails, phone numbers) to nixcfg
  _<sub>src: ~/Code/nixcfg/+agents/rules/SYSOP.md L308</sub>_
  <!-- rule_ids: SYSOP.md:L308:no-pii-in-config | cluster: — -->

- 🔴 **HARD** | `never` | Never commit secrets to git
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/SMARTHOME.md L410</sub>_
  <!-- rule_ids: SMARTHOME.md:L410:never-commit-secrets-smarthome | cluster: — -->

- 🔴 **HARD** | `never` | Never commit ~/Secrets/decrypted/ contents or plaintext secrets
  _<sub>src: ~/Code/nixcfg/docs/SECRETS.md L638-646</sub>_
  <!-- rule_ids: SECRETS.md:L639:never-commit-decrypted-or-plaintext | cluster: — -->

- 🔴 **HARD** | `never` | Secrets are never stored in plain text in this repo
  _<sub>src: ~/Code/nixcfg/docs/INFRASTRUCTURE.md L38</sub>_
  <!-- rule_ids: INFRASTRUCTURE.md:L38:secrets-never-plaintext | cluster: — -->

## Topic: security/ssh-keys

- 🔴 **HARD** | `never` | Family servers (hsb0, hsb8) MUST NOT allow external developer keys — always use lib.mkForce on authorizedKeys
  _<sub>src: ~/Code/nixcfg/hosts/hsb8/docs/RUNBOOK.md L337-338 · incident: 2025-11-22</sub>_
  <!-- rule_ids: hsb8-RUNBOOK.md:L337:family-servers-no-external-keys | cluster: — -->

- 🔴 **HARD** | `never` | SSH private keys may only be committed if encrypted with agenix
  _<sub>src: ~/Code/nixcfg/+agents/rules/SYSOP.md L310</sub>_
  <!-- rule_ids: SYSOP.md:L310:ssh-private-keys-only-via-agenix | cluster: — -->

- 🔴 **HARD** | `always` | hsb0 SSH only allows mba user; use lib.mkForce on authorizedKeys to block hokage external developer key injection
  _<sub>src: ~/Code/nixcfg/hosts/hsb0/docs/RUNBOOK.md L373-384</sub>_
  <!-- rule_ids: hsb0-RUNBOOK.md:L375:hsb0-mba-only-mkforce-keys | cluster: — -->

## Topic: incident-response/secret-leak

- 🔴 **HARD** | `always` | If just rekey wiped secrets to ~578 bytes, STOP — do not commit or push; restore via git reset --hard
  _<sub>src: ~/Code/nixcfg/docs/SECRETS.md L713-716</sub>_
  <!-- rule_ids: SECRETS.md:L713:after-wipe-do-not-commit-or-push | cluster: — -->

## Topic: secrets/access-pattern

- 🟡 **STRONG** | `do` | Materialized agent secret files use mode 0400 in a 0500 directory — read-only, one-way
  _<sub>src: ~/Code/nixcfg/docs/SECRETS.md L132</sub>_
  <!-- rule_ids: SECRETS.md:L132:agent-secrets-mode-0400-0500 | cluster: — -->

- 🟡 **STRONG** | `do` | Tier 1 system secrets live in secrets/ (NixOS servers); use agenix and just edit-secret commands
  _<sub>src: ~/Code/nixcfg/docs/SECRETS.md L100-103</sub>_
  <!-- rule_ids: SECRETS.md:L100:tier1-system-secrets-location | cluster: — -->

## Topic: secrets/agenix-pipeline

- 🔴 **HARD** | `do` | After rekey, look for 578-byte files (indicates corrupted/empty header only)
  _<sub>src: ~/Code/nixcfg/docs/SECRETS.md L75</sub>_
  <!-- rule_ids: SECRETS.md:L75:578-bytes-corrupted-marker | cluster: — -->

- 🔴 **HARD** | `do` | After secret rotation: gitpl && just switch && just <container>-rebuild — `just switch` required because agenix decrypts on NixOS switch, not docker rebuild
  _<sub>src: ~/Code/nixcfg/hosts/hsb0/docs/RUNBOOK.md L140-144</sub>_
  <!-- rule_ids: hsb0-RUNBOOK.md:L143:just-switch-required-after-secret-rotation | cluster: — -->

- 🔴 **HARD** | `always` | Global rekeys can SILENTLY WIPE secrets if SSH key missing; check file sizes before committing rekey changes
  _<sub>src: ~/Code/nixcfg/docs/SECRETS.md L73-77</sub>_
  <!-- rule_ids: SECRETS.md:L74:rekey-danger-check-file-sizes | cluster: — -->

- 🔴 **HARD** | `do` | In Nix configs reference passwords via _File path (config.age.secrets.foo.path), never inline plaintext
  _<sub>src: ~/Code/nixcfg/+agents/rules/SYSOP.md L319-327</sub>\_
  <!-- rule_ids: SYSOP.md:L321:agenix-pattern-use-pwfile-not-inline | cluster: — -->

- 🔴 **HARD** | `always` | Verify with `git diff --stat` BEFORE committing rekeyed secrets
  _<sub>src: ~/Code/nixcfg/docs/SECRETS.md L76</sub>_
  <!-- rule_ids: SECRETS.md:L76:verify-git-diff-stat-before-commit | cluster: — -->

- 🟡 **STRONG** | `do` | macOS hosts need one-time `sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key` to act as agenix recipients
  _<sub>src: ~/Code/nixcfg/docs/SECRETS.md L145-153</sub>_
  <!-- rule_ids: SECRETS.md:L150:macos-host-key-one-time-setup | cluster: — -->

## Topic: style/file-operations

- 🔴 **HARD** | `never` | Edit canonical files in +agents/rules/ directly; never edit the symlink targets — they are just pointers
  _<sub>src: ~/Code/nixcfg/+agents/README.md L37-39</sub>_
  <!-- rule_ids: +agents-README.md:L37:edit-canonical-files-not-symlinks | cluster: — -->

- 🔴 **HARD** | `never` | Only edit files in folder +agents when the user explicitly permits it
  _<sub>src: ~/Code/nixcfg/+agents/rules/AGENTS.md L22</sub>_
  <!-- rule_ids: AGENTS.md:L22:no-edit-+agents-without-permission | cluster: — -->

## Topic: tools/just

- 🟡 **STRONG** | `do` | At session start, run just --list to see available commands; read docs before coding
  _<sub>src: ~/Code/nixcfg/+agents/rules/AGENTS.md L49</sub>_
  <!-- rule_ids: AGENTS.md:L49:run-just-list-at-start | cluster: — -->

## Topic: tools/ssh

- 🟡 **STRONG** | `always` | Always check the host RUNBOOK first for SSH connection details
  _<sub>src: ~/Code/nixcfg/+agents/rules/AGENTS.md L213</sub>_
  <!-- rule_ids: AGENTS.md:L213:check-runbook-before-ssh | cluster: — -->

## Topic: tools/unicode-handling

- 🔴 **HARD** | `never` | Never edit stasysmo icons.sh manually — always regenerate with the Python helper to preserve Unicode
  _<sub>src: ~/Code/nixcfg/modules/uzumaki/stasysmo/README.md L199</sub>_
  <!-- rule_ids: stasysmo-README.md:L199:do-not-edit-icons-sh-manually | cluster: — -->

## Topic: tools/zellij

- 🟡 **STRONG** | `do` | For zellij theme overrides on gpc0, use lib.mkForce on source attribute and rm -rf ~/.config/zellij before first rebuild after theme change
  _<sub>src: ~/Code/nixcfg/hosts/gpc0/docs/RUNBOOK.md L83-86</sub>_
  <!-- rule_ids: gpc0-RUNBOOK.md:L84:zellij-theming-mkforce | cluster: — -->

## Topic: process/build-test

- 🟡 **STRONG** | `always` | Always verify changes before restarting the affected HA service
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/SMARTHOME.md L378-381</sub>_
  <!-- rule_ids: SMARTHOME.md:L378:verify-changes-before-restart | cluster: — -->

- 🟡 **STRONG** | `do` | Test new HA automations with dry-run first via Developer Tools → Services before automating
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/AUTOMATIONS.md L112</sub>_
  <!-- rule_ids: AUTOMATIONS.md:L112:test-with-dry-run-first | cluster: — -->

- 🟡 **STRONG** | `do` | Validate YAML after changes with python3 yaml.safe\*load
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/SMARTHOME.md L357-360</sub>_
  <!-- rule_ids: SMARTHOME.md:L358:validate-yaml-after-changes | cluster: — -->

- 🟢 SOFT | `do` | For new stasysmo manual tests, include a "Cannot be automated" notice and add to the Test Matrix
  _<sub>src: ~/Code/nixcfg/modules/uzumaki/stasysmo/tests/README.md L145-148</sub>_
  <!-- rule_ids: stasysmo-tests-README.md:L148:mark-cant-be-automated | cluster: — -->

## Topic: workflow/ppm

- 🔴 **HARD** | `never` | No markdown backlog files in the nixcfg repo (migrated, tagged backlog-final)
  _<sub>src: ~/Code/nixcfg/+agents/rules/AGENTS.md L254</sub>_
  <!-- rule_ids: AGENTS.md:L254:no-markdown-backlog-files | cluster: — -->

- 🟡 **STRONG** | `do` | In nixcfg PPM context, default project is NIX (project ID 1)
  _<sub>src: ~/Code/nixcfg/+agents/commands/ppm.md L27</sub>_
  <!-- rule_ids: ppm.md:L27:default-ppm-project-nix | cluster: — -->

## Topic: nixos/build-safety

- 🔴 **HARD** | `always` | Always define static networking declaratively for servers; set hashedPassword on mba for VNC console recovery
  _<sub>src: ~/Code/nixcfg/hosts/csb1/docs/RUNBOOK.md L273-279 · incident: 2025-12-05</sub>_
  <!-- rule_ids: csb1-RUNBOOK.md:L278:always-static-network-declaratively | cluster: — -->

- 🔴 **HARD** | `always` | Always use lib.mkForce for restic capabilities in modules/common.nix — duplicated capabilities cause SSH lockout
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/RUNBOOK.md L245-251</sub>_
  <!-- rule_ids: hsb1-RUNBOOK.md:L250:always-mkforce-restic-capabilities | cluster: — -->

- 🔴 **HARD** | `always` | Always verify gateway via DHCP (journalctl or ip route) before applying static IP config
  _<sub>src: ~/Code/nixcfg/hosts/csb0/docs/RUNBOOK.md L260-265 · incident: 2025-12-06</sub>_
  <!-- rule_ids: csb0-RUNBOOK.md:L265:verify-gateway-via-dhcp-before-static | cluster: — -->

- 🔴 **HARD** | `never` | Do NOT manually edit files on the server; edit compose locally, commit, push, git pull on host, then docker compose up -d
  _<sub>src: ~/Code/nixcfg/docs/INFRASTRUCTURE.md L28-33</sub>_
  <!-- rule_ids: INFRASTRUCTURE.md:L30:do-not-edit-files-on-server | cluster: — -->

- 🔴 **HARD** | `never` | For hsb2 (Pi Zero W), use linux/armv6 builds only; never use arm64 or armv7 builds
  _<sub>src: ~/Code/nixcfg/hosts/hsb2/docs/RUNBOOK.md L332</sub>_
  <!-- rule_ids: hsb2-RUNBOOK.md:L332:hsb2-armv6-only-never-arm64 | cluster: — -->

- 🔴 **HARD** | `never` | Never build NixOS configs on macOS — use a Linux build host
  _<sub>src: ~/Code/nixcfg/+agents/rules/AGENTS.md L184</sub>_
  <!-- rule_ids: AGENTS.md:L184:never-build-nixos-on-macos | cluster: — -->

- 🔴 **HARD** | `never` | NixOS configurations can only be built on NixOS hosts
  _<sub>src: ~/Code/nixcfg/docs/INFRASTRUCTURE.md L246</sub>_
  <!-- rule_ids: INFRASTRUCTURE.md:L246:nixos-can-only-build-on-nixos | cluster: — -->

- 🔴 **HARD** | `always` | hsb8 location switch (jhw22<->ww87) requires physical console access — network gateway changes during switch
  _<sub>src: ~/Code/nixcfg/hosts/hsb8/docs/RUNBOOK.md L70-71</sub>_
  <!-- rule_ids: hsb8-RUNBOOK.md:L70:location-switch-needs-physical-access | cluster: — -->

- 🟡 **STRONG** | `do` | For heavy NixOS rebuilds on gpc0, use `systemd-inhibit --what=sleep:idle` to prevent the machine from sleeping
  _<sub>src: ~/Code/nixcfg/hosts/gpc0/docs/RUNBOOK.md L64-68</sub>_
  <!-- rule_ids: gpc0-RUNBOOK.md:L65:systemd-inhibit-on-heavy-rebuilds | cluster: — -->

- 🟡 **STRONG** | `do` | On hsb8, DHCP is disabled by default for safety; only enable when ready to take over from old router/Pi-hole
  _<sub>src: ~/Code/nixcfg/hosts/hsb8/docs/RUNBOOK.md L363-365</sub>_
  <!-- rule_ids: hsb8-RUNBOOK.md:L362:dhcp-disabled-by-default | cluster: — -->

## Topic: nixos/host-template

- 🔴 **HARD** | `always` | On hsb1: every managed file must be a symlink back to nixcfg; if it is not a symlink, it is not managed
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/RUNBOOK.md L89-93</sub>_
  <!-- rule_ids: hsb1-RUNBOOK.md:L91:every-managed-file-is-symlink | cluster: — -->

## Topic: infra/cloudflare-dns

- 🟡 **STRONG** | `prefer` | Use Cloudflare proxy for public-facing services (docmost, paperless); use DNS-only for SSH, MQTT, direct DB, and admin interfaces
  _<sub>src: ~/Code/nixcfg/infrastructure/cloudflare/dns-barta-cm.md L183-191</sub>_
  <!-- rule_ids: dns-barta-cm.md:L185:proxy-public-services-not-admin | cluster: — -->

## Topic: infra/headscale

- 🔴 **HARD** | `always` | hs.barta.cm must be DNS-only in Cloudflare (NOT proxied) — proxy breaks WebSocket POSTs
  _<sub>src: ~/Code/nixcfg/hosts/csb0/docs/RUNBOOK.md L426</sub>_
  <!-- rule_ids: csb0-RUNBOOK.md:L426:hs-barta-cm-dns-only-not-proxied | cluster: — -->

## Topic: infra/home-automation

- 🔴 **HARD** | `always` | For new automations use explicit entity lists only — never target all or entire areas blindly
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/AUTOMATIONS.md L110</sub>_
  <!-- rule_ids: AUTOMATIONS.md:L110:explicit-entity-lists-only | cluster: — -->

- 🔴 **HARD** | `never` | Never use WiFi presence (zone.home<1) to trigger destructive actions like turning off lights
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/AUTOMATIONS.md L11-17 · incident: 2026-03-20</sub>_
  <!-- rule_ids: AUTOMATIONS.md:L13:no-wifi-presence-destructive-trigger | cluster: — -->

- 🔴 **HARD** | `never` | Never use entity\*id: "all" or area-based targets without reviewing what entities exist in that scope
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/AUTOMATIONS.md L28</sub>_
  <!-- rule_ids: AUTOMATIONS.md:L29:no-broad-entity-area-targeting | cluster: — -->

- 🔴 **HARD** | `never` | No automation should ever target entity\*id: "all" for any domain
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/AUTOMATIONS.md L22 · incident: 2026-03-20</sub>_
  <!-- rule_ids: AUTOMATIONS.md:L22:no-entity-id-all-targeting | cluster: — -->

- 🔴 **HARD** | `never` | No automation should use WiFi presence count as a trigger for device control
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/AUTOMATIONS.md L23</sub>_
  <!-- rule_ids: AUTOMATIONS.md:L23:no-wifi-presence-trigger-device-control | cluster: — -->

- 🟡 **STRONG** | `always` | Always back up HA configuration.yaml before making changes
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/SMARTHOME.md L344-349</sub>_
  <!-- rule_ids: SMARTHOME.md:L344:always-backup-ha-config-before-changes | cluster: — -->

- 🟡 **STRONG** | `do` | If presence-based automations needed: use multiple signals (BLE+WiFi+motion), require sustained absence (>30min), explicit entity lists
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/AUTOMATIONS.md L23</sub>_
  <!-- rule_ids: AUTOMATIONS.md:L24:presence-need-multiple-signals | cluster: — -->

- 🟡 **STRONG** | `always` | In HA HomeKit entity\*config, always prefix the literal room name to the entity name (e.g. "Terrasse D28")
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/SMARTHOME.md L321-331</sub>_
  <!-- rule_ids: SMARTHOME.md:L325:homekit-prefix-room-name | cluster: — -->

- 🟡 **STRONG** | `do` | Zigbee2MQTT naming convention: room/type/device\*name (e.g. bz/light/mirror, ku/plug/coffee)
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/SMARTHOME.md L335</sub>_
  <!-- rule_ids: SMARTHOME.md:L335:z2m-naming-room-type-name | cluster: — -->

## Topic: infra/mqtt

- 🟡 **STRONG** | `always` | Always use localhost for MQTT broker in Home Assistant on hsb1 (not hostnames) to prevent reconnect failures on hostname change
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/RUNBOOK.md L233</sub>_
  <!-- rule_ids: hsb1-RUNBOOK.md:L233:always-localhost-for-mqtt-in-ha | cluster: — -->

- 🟡 **STRONG** | `never` | Never use a hostname for the HA MQTT broker setting — use localhost or IP
  _<sub>src: ~/Code/nixcfg/hosts/hsb1/docs/RUNBOOK.md L470-472</sub>_
  <!-- rule_ids: hsb1-RUNBOOK.md:L472:never-hostname-for-mqtt-broker | cluster: — -->

## Topic: infra/netcup

- 🟡 **STRONG** | `do` | Netcup VNC has German keyboard layout: hyphen, backslash, colon, pipe do NOT work; plan commands accordingly
  _<sub>src: ~/Code/nixcfg/hosts/csb1/docs/RUNBOOK.md L286-300</sub>_
  <!-- rule_ids: csb1-RUNBOOK.md:L301:netcup-vnc-keyboard-issues | cluster: — -->

- 🟡 **STRONG** | `do` | csb0 subnet is /22 (NOT /24) — gateway is in .64 subnet at .64.1, not .65.1
  _<sub>src: ~/Code/nixcfg/docs/INFRASTRUCTURE.md L280 · ~/Code/nixcfg/hosts/csb0/README.md L170 · incident: 2025-12-06</sub>_
  <!-- rule_ids: INFRASTRUCTURE.md:L280:csb0-subnet-22-not-24,csb0-README.md:L170:csb0-subnet-22-gateway-64 | cluster: other-netcup-quirks-001 -->
