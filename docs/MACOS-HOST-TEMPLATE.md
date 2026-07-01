# macOS Host Directory Template

Reference for the file structure of a new macOS host. **Sister doc** to [NIXOS-HOST-TEMPLATE.md](./NIXOS-HOST-TEMPLATE.md) — that one covers NixOS hosts, this one covers macOS.

> **Procedural setup walkthrough**: see [MACOS-SETUP.md](./MACOS-SETUP.md). This doc is the **structural reference** (what files go where, what HM modules to enable). MACOS-SETUP.md is the **runbook** (commands in order, with troubleshooting).

> **Related**: [AGENT-WORKFLOW.md](./AGENT-WORKFLOW.md) — keeping config / docs / tests in sync as you change things.

---

## Required Structure

```text
hosts/<hostname>/
├── home.nix                  # Per-user Home Manager config (REQUIRED)
├── README.md                 # Host overview + Quick Reference (REQUIRED)
├── ip-<address>.md           # IP marker file for quick identification
├── runbook-secrets.age       # Encrypted secrets reference for Git
│
├── docs/
│   └── RUNBOOK.md            # Operational procedures (REQUIRED)
│
├── scripts/
│   └── host-user/            # Per-host imperative helpers (optional)
│
├── secrets/
│   └── runbook-secrets.md    # Plain text credentials (gitignored, for local editing)
│
└── tests/
    ├── README.md             # Test overview
    └── T00-host-base.sh      # Base host verification (optional but recommended)
```

There is **no** `configuration.nix` or `hardware-configuration.nix` — those are NixOS-only. macOS hosts are managed entirely by Home Manager (and Homebrew for GUI apps that aren't nix-darwin-managed).

Karabiner follows the macOS hybrid pattern: `modules/uzumaki/home-manager.nix`
wires the shared JSON config from `modules/config/karabiner.json`, while the
Karabiner-Elements app itself is installed manually with Homebrew and approved
in System Settings → Privacy & Security → Input Monitoring.

---

## File Descriptions

| File                         | Purpose                                                             | Required           |
| ---------------------------- | ------------------------------------------------------------------- | ------------------ |
| `home.nix`                   | Home Manager module — packages, programs, theme, INSPR wiring       | ✅ Yes             |
| `README.md`                  | Host overview, Quick Reference table                                | ✅ Yes             |
| `docs/RUNBOOK.md`            | Operational procedures, recovery steps                              | ✅ Yes             |
| `ip-<address>.md`            | IP marker for quick identification (Tailscale 100.64.\* and/or LAN) | ✅ Yes             |
| `runbook-secrets.age`        | Encrypted backup of secrets reference (NOT consumed at runtime)     | ✅ Yes             |
| `secrets/runbook-secrets.md` | Gitignored credentials reference (plain text, local-only)           | ⚠️ When applicable |
| `scripts/host-user/`         | Per-host bash/fish helpers run interactively                        | Optional           |
| `tests/`                     | Smoke / verification scripts                                        | Recommended        |

---

## Critical Prerequisite — macOS host as agenix recipient

Unlike NixOS, **macOS does NOT auto-generate `/etc/ssh/ssh_host_ed25519_key`**. Without this key, the host cannot decrypt agenix `.age` secrets (whether system-wide via nix-darwin agenix, or per-user via the `inspr.secrets.agents` HM module that uses the user SSH key).

For Markus's fleet, agent-secrets is HM-level (decrypts via the user's `~/.ssh/id_ed25519`), not host-level. But the **host key is still useful** if the host ever needs system-level agenix secrets (e.g. for nix-darwin-managed services). Generate it manually on every fresh macOS host:

```bash
sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" \
     -C "root@<hostname>"
```

If the host needs to be a recipient of `.age` secrets:

1. Capture the public key:
   ```bash
   sudo cat /etc/ssh/ssh_host_ed25519_key.pub
   ```
2. Add it to `secrets/secrets.nix` under the `MACOS HOSTS` section as a new var (see the `mbp0` entry as a template).
3. Add the host to all relevant secret recipient lists (e.g. `agents/host/<hostname>/<NAME>.age` — see imac0 entries for the user-key-only pattern, or m5 for the host-key-as-recipient pattern).
4. `just rekey` if existing shared secrets need to admit this new host.

(Note: `inspr.secrets.agents` uses USER keys, not host keys — so most macOS hosts don't need step 3 at all. The host key is only needed for system-level agenix.)

---

## INSPR HM Module Wiring

Each macOS host enables INSPR's HM modules via the **two-import pattern** — `inputs.inspr-modules.homeManagerModules.<name>` provides the mechanic, `modules/shared/markus-defaults.nix` provides the values:

```nix
imports = [
  ../../modules/shared/markus-defaults.nix   # context defaults (atelier, identities, presets)
  # plus per-host extras as needed
];

# Enable each module the host wants active
inspr.secrets.agents.enable        = true;
inspr.paimos-cli.enable            = true;
inspr.git-identity.enable          = true;
inspr.git.atelier.personal.enable  = true;
inspr.git.atelier.bytepoets.enable = true;  # only on hosts that touch BYTEPOETS work
inspr.ssh.authorized = {
  enable = true;
  trust  = config._inspr.trustPresets.personalHosts
        ++ config._inspr.trustPresets.bytepoetsInbound;  # adjust per host
};
```

Module surface (defined in [inspr-modules](https://github.com/markus-barta/inspr-modules)):

| Module                                   | What it does                                                                                            |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `inspr.secrets.agents`                   | Decrypts agenix `.age` files at HM activation → `~/.inspr/secrets/agents/*.env` (mode 0400)             |
| `inspr.paimos-cli`                       | Auto-bootstraps `~/.paimos/config.yaml` from the configured PPM / PMO instances                         |
| `inspr.ssh.authorized`                   | Declarative `~/.ssh/authorized_keys` from trust presets (personalHosts, bytepoetsInbound, etc.)         |
| `inspr.git.atelier.{personal,bytepoets}` | Federated git auth via per-host SSH userkeys (INSPR-170 Strategy B)                                     |
| `inspr.git-identity`                     | Context-aware `[user]` and `includeIf` git config (personal default, BYTEPOETS override on org remotes) |

---

## home.nix Skeleton

Use the `imac0` or `mbp0` `home.nix` as a starting template — both are mature reference implementations. The minimum viable skeleton is:

```nix
{
  config,    # REQUIRED: bound for ${config.xdg.configHome}, ${config._inspr.trustPresets.*}
  pkgs,
  lib,
  inputs,
  ...
}:

{
  imports = [
    ../../modules/uzumaki/home-manager.nix
    ../../modules/shared/markus-defaults.nix
  ];

  uzumaki = {
    enable = true;
    role = "workstation";
    fish.editor = "nano";
    stasysmo.enable = true;
  };

  theme.hostname = "<hostname>";              # MUST match scutil hostname

  home.username      = "<user>";              # markus or mba (see naming)
  home.homeDirectory = "/Users/<user>";
  home.stateVersion  = "24.11";
  home.enableNixpkgsReleaseCheck = false;
  programs.home-manager.enable = true;

  # INSPR module enable flags — see preceding section
  inspr.secrets.agents.enable = true;
  # ...
}
```

**Username convention** (per fleet):

| User     | Hosts using it            |
| -------- | ------------------------- |
| `markus` | `imac0`                   |
| `mba`    | `mbp0` and other MacBooks |

Always confirm with `whoami` on the target host before populating `home.username`.

---

## README.md Template

```markdown
# <hostname> — Short Description

Brief description of this machine.

## Quick Reference

| Item               | Value                    |
| ------------------ | ------------------------ |
| **Hostname**       | `<hostname>`             |
| **Model**          | MacBook Pro / iMac / etc |
| **OS**             | macOS XX.X               |
| **Architecture**   | Apple Silicon / Intel    |
| **User**           | `<username>`             |
| **Shell**          | Fish (via Nix)           |
| **Config Manager** | home-manager             |
| **Apply Config**   | `just switch`            |
| **Theme**          | warmGray / lightGray / … |
| **Tailscale IP**   | `100.64.x.x`             |
| **LAN IP**         | `<ip>` (if applicable)   |

## Features

| ID  | Feature          | Description                                                          |
| --- | ---------------- | -------------------------------------------------------------------- |
| F00 | Nix Base System  | Reproducible package management                                      |
| F01 | Fish Shell       | Modern shell with functions                                          |
| F02 | Starship Prompt  | Themed prompt                                                        |
| F03 | Ghostty Terminal | (managed via Homebrew, not Nix — was WezTerm pre-2026-05-05)         |
| F04 | INSPR Modules    | agent-secrets, paimos-cli, ssh-authorized, git-atelier, git-identity |
| F05 | Atelier Git Auth | Per-host SSH userkeys; federated push/pull (INSPR-170)               |

## Setup History

- YYYY-MM-DD — initial home-manager apply
- YYYY-MM-DD — added to atelier (personal + BYTEPOETS as applicable)
- YYYY-MM-DD — admitted as agenix recipient (if applicable)
```

---

## docs/RUNBOOK.md Template

```markdown
# <hostname> Runbook

Operational procedures.

## Quick Commands

| Task             | Command                                                |
| ---------------- | ------------------------------------------------------ |
| Apply config     | `home-manager switch --flake ".#<user>@<hostname>"`    |
| via just         | `cd ~/Code/nixcfg && just switch`                      |
| INSPR self-test  | `~/Code/inspr/scripts/inspr-doctor.sh`                 |
| Update lock      | `nix flake update`                                     |
| List generations | `home-manager generations`                             |
| Rollback         | `home-manager generations` → switch a prior generation |

## Common Issues

### `home-manager switch` fails with "Path 'hosts/...' not tracked"

Run `git add hosts/<hostname>/` before switch — flakes only see git-tracked files.

### Agent secrets fail to materialize

Run `inspr-doctor.sh --verbose` for the secrets-pipeline checks.

### INSPR-onboarded?

`~/Code/inspr/scripts/inspr-doctor.sh` — fix what it flags.

## Service-Specific Procedures

[per-host services and their operational quirks]
```

---

## tests/README.md Template

```markdown
# <hostname> Tests

Smoke / verification scripts.

## Running

    ./run-all-tests.sh
    ./T00-host-base.sh

## Test Index

| Test | Description | Script             |
| ---- | ----------- | ------------------ |
| T00  | Host base   | `T00-host-base.sh` |
| T01  | <Service 1> | `T01-<service>.sh` |
```

---

## Checklist for New macOS Host

- [ ] **Setup** — follow [MACOS-SETUP.md](./MACOS-SETUP.md) Phase 1–6 first
- [ ] **Generate host SSH key**: `sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -C "root@<hostname>"`
- [ ] **Create directory structure**: `mkdir -p hosts/<hostname>/{docs,scripts/host-user,secrets,tests}`
- [ ] **Add `home.nix`** (start from `imac0` or `mbp0`)
- [ ] **Customize**: `theme.hostname`, `home.username`, `home.homeDirectory`, INSPR module enables
- [ ] **Theme palette**: add hostname → palette in `modules/uzumaki/theme/theme-palettes.nix`
- [ ] **Register in `flake.nix`** under `homeConfigurations` (correct `system = "x86_64-darwin"` or `aarch64-darwin"`)
- [ ] **Add IP marker**: `touch hosts/<hostname>/ip-<address>.md`
- [ ] **Create `README.md`** with Quick Reference
- [ ] **Create `docs/RUNBOOK.md`**
- [ ] **(If recipient) Add host pubkey** to `secrets/secrets.nix` MACOS HOSTS section + relevant recipient lists; `just rekey`
- [ ] **(If on atelier) Generate per-host atelier userkeys** — see `modules/shared/markus-defaults.nix` `hostKeys` table for the pattern
- [ ] **Run `inspr-doctor.sh`** — fix every red until summary line is green
- [ ] **First commit**: `git add hosts/<hostname>/ flake.nix modules/uzumaki/theme/theme-palettes.nix [secrets/secrets.nix]`
- [ ] **Switch**: `nix run home-manager -- switch --flake ".#<user>@<hostname>"` (first time) or `just switch` (subsequent)

---

## Related Documentation

- [MACOS-SETUP.md](./MACOS-SETUP.md) — full procedural setup guide (Phase 1–6, troubleshooting)
- [NIXOS-HOST-TEMPLATE.md](./NIXOS-HOST-TEMPLATE.md) — sister doc, NixOS hosts only
- [AGENT-WORKFLOW.md](./AGENT-WORKFLOW.md) — keeping config / docs / tests in sync
- [Uzumaki module](../modules/uzumaki/README.md) — fish functions, theming, role/profile flags
- [inspr-modules](https://github.com/markus-barta/inspr-modules) — public flake providing the inspr.\* HM modules
- [inspr/playbook.md](../../inspr/playbook.md) (private) — narrative field notes from real onboardings; the “why” behind the canonical patterns

---

**Last Updated:** 2026-05-14  
**Maintainer:** Markus Barta
