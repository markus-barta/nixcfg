# merlin-ssh-access-hsb1

**Host**: hsb1 (+ hsb0 for container-side changes)
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-22

---

## Problem

Merlin (openclaw-gateway container on hsb0) needs direct access to hsb1 to manage Home Assistant configuration files, Node-RED flows, and other Docker-based services. The HA REST API is too limited for the volume and type of changes required. Future services (Node-RED, Zigbee2MQTT, etc.) will also need direct management.

## Solution

Create a dedicated `merlin` user on hsb1 with full host access (`wheel` + `docker` groups) and SSH key authentication. The SSH private key is stored as an agenix secret on hsb0, mounted into the openclaw-gateway container. An SSH config file inside the container handles key selection automatically — no wrapper scripts or tool-level config needed.

**Design decisions:**

- Dedicated `merlin` user (not `mba`) for clean audit trail + easy revocation
- `wheel` + `docker` = full host control — intentional, hsb1 is home automation / fun only
- SSH config file mounted into container (not a wrapper script)
- Ed25519 key (no passphrase — it's a non-interactive container)

## Implementation

### Phase 1: Generate SSH keypair (human — requires local machine)

- [ ] **1.1** Generate keypair:
  ```bash
  ssh-keygen -t ed25519 -C "merlin@openclaw-gateway-hsb0" -f /tmp/merlin-hsb1-ssh-key -N ""
  ```
- [ ] **1.2** Encrypt private key with agenix (from nixcfg repo root):
  ```bash
  # First add the secret definition to secrets/secrets.nix (see step 2.1),
  # then encrypt:
  cp /tmp/merlin-hsb1-ssh-key /tmp/merlin-ssh-key-plain
  agenix -e secrets/hsb0-merlin-ssh-key.age < /tmp/merlin-ssh-key-plain
  # Or interactively: agenix -e secrets/hsb0-merlin-ssh-key.age
  # then paste the private key contents
  ```
- [ ] **1.3** Save public key to repo (plaintext, safe to commit):
  ```bash
  cp /tmp/merlin-hsb1-ssh-key.pub keys/merlin-hsb1.pub
  ```
- [ ] **1.4** Securely delete temp files:
  ```bash
  rm /tmp/merlin-hsb1-ssh-key /tmp/merlin-hsb1-ssh-key.pub /tmp/merlin-ssh-key-plain
  ```

### Phase 2: NixOS configuration changes (AI can do — propose + get OK)

- [ ] **2.1** Add secret to `secrets/secrets.nix`:

  ```nix
  # In the hsb0 secrets section, add:
  "hsb0-merlin-ssh-key.age".publicKeys = markus ++ hsb0;
  ```

  (Pattern: follows existing `hsb0-openclaw-*.age` naming; recipients = markus + hsb0 only)

- [ ] **2.2** Add agenix secret definition to `hosts/hsb0/configuration.nix`:

  ```nix
  # After the existing openclaw secrets block (~line 540):
  age.secrets.hsb0-merlin-ssh-key = {
    file = ../../secrets/hsb0-merlin-ssh-key.age;
    mode = "444";  # Readable by container (node user, uid 1000)
  };
  ```

  (Pattern: matches existing openclaw secrets — `mode = "444"`, no owner/group)

- [ ] **2.3** Add `merlin` user to `hosts/hsb1/configuration.nix`:
  ```nix
  # After the mba user block (~line 462):
  users.users.merlin = {
    isNormalUser = true;
    description = "Merlin AI Agent (OpenClaw on hsb0)";
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.bash;
    # No password — SSH key auth only
    hashedPassword = "!";  # Locked password, SSH only
    openssh.authorizedKeys.keys = [
      "<contents of keys/merlin-hsb1.pub>"  # Ed25519 key from Phase 1
    ];
  };
  ```
  (No explicit UID needed — NixOS auto-assigns. No `lib.mkForce` needed since this is a new user.)

### Phase 3: Container-side changes (AI can do — propose + get OK)

- [ ] **3.1** Create SSH config file at `hosts/hsb0/docker/openclaw-gateway/ssh_config`:

  ```
  Host hsb1 hsb1.lan
      HostName hsb1.lan
      User merlin
      IdentityFile /run/secrets/merlin-ssh-key
      StrictHostKeyChecking accept-new
      UserKnownHostsFile /home/node/.ssh/known_hosts
  ```

  (Note: `accept-new` auto-accepts on first connect but rejects changed keys — safer than `no`)

- [ ] **3.2** Add volume mounts to `hosts/hsb0/docker/docker-compose.yml` (openclaw-gateway service):

  ```yaml
  # Under "# MERLIN-specific secrets" section (~line 61), add:
  - /run/agenix/hsb0-merlin-ssh-key:/run/secrets/merlin-ssh-key:ro
  # Under volumes section, add SSH config:
  - ./openclaw-gateway/ssh_config:/home/node/.ssh/config:ro
  ```

- [ ] **3.3** Install `openssh-client` in `hosts/hsb0/docker/openclaw-gateway/Dockerfile`:

  ```dockerfile
  # Add openssh-client to the apt-get install line (~line 3):
  RUN apt-get update && apt-get install -y git curl jq vdirsyncer khal mosquitto-clients python3 build-essential openssh-client && rm -rf /var/lib/apt/lists/* \
  ```

- [ ] **3.4** Add `.ssh` directory creation to Dockerfile (~line 20, inside the existing mkdir block):

  ```dockerfile
  # Add to the existing mkdir -p block:
  /home/node/.ssh \
  ```

  And add to the existing chown:

  ```dockerfile
  && chown -R node:node /home/node/.openclaw /home/node/.config /home/node/.ssh /home/node/entrypoint.sh
  ```

- [ ] **3.5** Set correct permissions on SSH key in `entrypoint.sh` (add after line 47, before config deployment):
  ```sh
  # --- SSH key permissions (agenix mounts as 444, SSH requires 600) ---
  if [ -f /run/secrets/merlin-ssh-key ]; then
    cp /run/secrets/merlin-ssh-key /home/node/.ssh/merlin-hsb1
    chmod 600 /home/node/.ssh/merlin-hsb1
    echo "[ssh] Merlin SSH key installed for hsb1 access"
  fi
  ```
  And update `ssh_config` to point to the copy:
  ```
  IdentityFile /home/node/.ssh/merlin-hsb1
  ```
  (Reason: SSH refuses keys with mode 444. We copy from read-only mount to writable location with correct perms.)

### Phase 4: Deploy (human — both hsb0 and hsb1 need rebuilds)

- [ ] **4.1** Commit all changes, push to GitHub
- [ ] **4.2** Deploy hsb1 first (creates merlin user):
  ```bash
  # From hsb1 or via SSH:
  cd ~/Code/nixcfg && git pull && sudo nixos-rebuild switch --flake .#hsb1
  # ~5-10 min
  ```
- [ ] **4.3** Deploy hsb0 second (adds agenix secret to /run/agenix/):
  ```bash
  # From hsb0 or via SSH:
  cd ~/Code/nixcfg && git pull && sudo nixos-rebuild switch --flake .#hsb0
  # ~5-10 min
  ```
- [ ] **4.4** Rebuild openclaw-gateway container on hsb0:
  ```bash
  cd ~/docker && docker compose up -d --build openclaw-gateway
  # ~3-5 min
  ```

### Phase 5: Verification tests (AI can SSH for read-only checks)

- [ ] **5.1** From inside the container, test SSH connectivity:
  ```bash
  docker exec openclaw-gateway ssh hsb1.lan "hostname && whoami"
  # Expected: hsb1 / merlin
  ```
- [ ] **5.2** Test file access to HA config:
  ```bash
  docker exec openclaw-gateway ssh hsb1.lan "ls -la /home/mba/docker/mounts/homeassistant/configuration.yaml"
  ```
- [ ] **5.3** Test docker exec into HA:
  ```bash
  docker exec openclaw-gateway ssh hsb1.lan "docker exec homeassistant cat /config/configuration.yaml | head -5"
  ```
- [ ] **5.4** Test docker compose restart:
  ```bash
  docker exec openclaw-gateway ssh hsb1.lan "cd /home/mba/docker && docker compose restart homeassistant"
  ```
- [ ] **5.5** Test sudo:
  ```bash
  docker exec openclaw-gateway ssh hsb1.lan "sudo whoami"
  # Expected: root
  ```

### Phase 6: Documentation updates (AI can do)

- [ ] **6.1** Update `hosts/hsb1/docs/RUNBOOK.md`: document merlin user, purpose, SSH access from hsb0
- [ ] **6.2** Update `docs/INFRASTRUCTURE.md`: add hsb0→hsb1 SSH dependency to dependency diagram/table

## Acceptance Criteria

- [ ] `merlin` user exists on hsb1, SSH key auth only, no password login
- [ ] `merlin` in `wheel` + `docker` groups (full host access)
- [ ] openclaw-gateway container on hsb0 can `ssh hsb1.lan` without prompts
- [ ] Full sudo access works (`sudo whoami` returns `root`)
- [ ] `docker exec homeassistant` works from SSH session
- [ ] `docker compose restart homeassistant` works from SSH session
- [ ] HA config files are readable/writable by merlin
- [ ] No plain-text secrets committed (private key in `.age` only)
- [ ] RUNBOOK.md + INFRASTRUCTURE.md updated
- [ ] SSH key permissions handled correctly (600 inside container)

## Notes

- **Criticality**: hsb1 = 🟡 Medium — home automation, fun stuff, home LAN only
- **Audit trail**: all merlin actions show as `merlin` in sshd/auth logs on hsb1
- **Revocation**: remove `users.users.merlin` from hsb1 config + rebuild = instant lockout
- **Key security**: private key lives in `/run/agenix/` (tmpfs) on hsb0, never on disk unencrypted; inside container it's copied to `/home/node/.ssh/` with mode 600 (ephemeral, lost on container restart)
- **SSH host key**: `StrictHostKeyChecking accept-new` auto-trusts on first connect; if hsb1 is rebuilt, delete `/home/node/.ssh/known_hosts` inside container (or `docker exec openclaw-gateway ssh-keygen -R hsb1.lan`)
- **Deploy order matters**: hsb1 first (creates user), hsb0 second (deploys secret), then container rebuild
- **HA config path on host**: likely `/home/mba/docker/mounts/homeassistant/` — confirm via `ssh mba@hsb1.lan ls -la ~/docker/mounts/homeassistant/` before wiring
- **Future scope**: same SSH access works for Node-RED (`~/docker/mounts/nodered/`), Zigbee2MQTT, Mosquitto, and any other service on hsb1
- **Risk accepted**: `wheel` group = effectively root on hsb1; justified by low-stakes nature of host
