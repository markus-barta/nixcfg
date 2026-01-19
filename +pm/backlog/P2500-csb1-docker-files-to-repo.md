# 2026-01-17 - csb1 Docker Files Migration to Git Repository

## Description

Migrate csb1 docker configuration files to git repository for version control, matching the pattern established on csb0. Currently csb1's docker-compose.yml and related configs only exist on the server (not version controlled).

## Context

**Current State:**

- **csb0:** Docker files in `hosts/csb0/docker/` (git repo) ✅
  - Proper structure with `systemd.tmpfiles`
  - Immutable config symlinked from repo
  - Mutable state in `/var/lib/csb0-docker/`
- **csb1:** Docker files only in `/home/mba/docker/` (NOT in git) ❌
  - No version control
  - No declarative management
  - Risk of config drift
  - Manual management required

**Why This Matters:**

- Version control for infrastructure-as-code
- Disaster recovery (can rebuild from git)
- Change tracking and rollback capability
- Consistency with csb0 pattern

## Acceptance Criteria

### 1. Copy Docker Files to Repo

- [ ] Create directory structure:

  ```bash
  mkdir -p hosts/csb1/docker/{traefik,restic-cron}
  ```

- [ ] Copy current files from csb1:

  ```bash
  # From local machine
  cd ~/Code/nixcfg
  scp -P 2222 mba@cs1.barta.cm:~/docker/docker-compose.yml hosts/csb1/docker/
  scp -P 2222 mba@cs1.barta.cm:~/docker/traefik/static.yml hosts/csb1/docker/traefik/
  scp -P 2222 mba@cs1.barta.cm:~/docker/traefik/dynamic.yml hosts/csb1/docker/traefik/
  scp -P 2222 -r mba@cs1.barta.cm:~/docker/restic-cron/* hosts/csb1/docker/restic-cron/
  ```

- [ ] **Do NOT copy:**
  - `acme.json` (mutable, Docker writes to it)
  - `variables.env` (secret, managed by agenix)
  - Any `.env` files with credentials

- [ ] Add to git:
  ```bash
  git add hosts/csb1/docker/
  git commit -m "feat(csb1): add docker configuration files to repo"
  ```

### 2. Update csb1 Configuration

- [ ] Update `hosts/csb1/configuration.nix` with systemd.tmpfiles rules:

  ```nix
  systemd.tmpfiles.rules = let
    dockerRoot = "/var/lib/csb1-docker";
    repoDockerFiles = "/home/mba/Code/nixcfg/hosts/csb1/docker";
  in [
    # Create runtime directory structure
    "d ${dockerRoot} 0755 mba users -"
    "d ${dockerRoot}/traefik 0755 mba users -"
    "d ${dockerRoot}/restic-cron 0755 mba users -"

    # Symlink immutable config files from git repo
    "L+ ${dockerRoot}/docker-compose.yml - - - - ${repoDockerFiles}/docker-compose.yml"
    "L+ ${dockerRoot}/traefik/static.yml - - - - ${repoDockerFiles}/traefik/static.yml"
    "L+ ${dockerRoot}/traefik/dynamic.yml - - - - ${repoDockerFiles}/traefik/dynamic.yml"

    # Symlink restic-cron scripts
    "L+ ${dockerRoot}/restic-cron/backup.sh - - - - ${repoDockerFiles}/restic-cron/backup.sh"
    "L+ ${dockerRoot}/restic-cron/cleanup.sh - - - - ${repoDockerFiles}/restic-cron/cleanup.sh"
    "L+ ${dockerRoot}/restic-cron/check.sh - - - - ${repoDockerFiles}/restic-cron/check.sh"
    "L+ ${dockerRoot}/restic-cron/Dockerfile - - - - ${repoDockerFiles}/restic-cron/Dockerfile"

    # Create mutable files (Docker writes to these)
    "f ${dockerRoot}/traefik/acme.json 0600 root root -"

    # Legacy compatibility symlink
    "L+ /home/mba/docker - - - - ${dockerRoot}"
  ];
  ```

- [ ] Update agenix secret path:

  ```nix
  age.secrets.traefik-variables = {
    file = ../../secrets/traefik-variables.age;
    path = "/var/lib/csb1-docker/traefik/variables.env";  # Changed from /home/mba/docker
    owner = "root";
    group = "root";
    mode = "0644";
  };
  ```

- [ ] Commit configuration changes

### 3. Deploy and Migrate

**Pre-deployment:**

- [ ] Backup current acme.json:
  ```bash
  ssh mba@cs1.barta.cm -p 2222 "sudo tar czf ~/docker-backup-$(date +%Y%m%d-%H%M%S).tar.gz ~/docker/traefik/acme.json"
  ```

**Deploy:**

- [ ] Push changes to GitHub
- [ ] SSH to csb1 and deploy:
  ```bash
  ssh mba@cs1.barta.cm -p 2222
  cd ~/Code/nixcfg
  git pull
  sudo nixos-rebuild switch --flake .#csb1
  ```

**Post-deployment:**

- [ ] Verify directory structure:
  ```bash
  ls -la /var/lib/csb1-docker/
  ls -la /var/lib/csb1-docker/traefik/
  ```
- [ ] Restore acme.json:
  ```bash
  sudo tar xzf ~/docker-backup-*.tar.gz -C /var/lib/csb1-docker/
  ```
- [ ] Restart Traefik:
  ```bash
  cd ~/docker && docker compose restart traefik
  ```

### 4. Verification

- [ ] Check symlinks correct:

  ```bash
  readlink /home/mba/docker  # Should point to /var/lib/csb1-docker
  readlink /var/lib/csb1-docker/docker-compose.yml  # Should point to repo
  ```

- [ ] Verify services working:
  - `curl -sI https://grafana.barta.cm` (expect HTTP/2 302)
  - `curl -sI https://influxdb.barta.cm` (expect HTTP/2 200)
  - `curl -sI https://docmost.barta.cm` (expect HTTP/2 200)
  - `curl -sI https://paperless.barta.cm` (expect HTTP/2 200)

- [ ] Check Traefik logs for errors:
  ```bash
  docker logs csb1-traefik-1 --tail 50
  ```

### 5. Documentation

- [ ] Update `hosts/csb1/README.md`:
  - Document new directory structure
  - Update deployment procedures
- [ ] Update `hosts/csb1/docs/RUNBOOK.md`:
  - Document `/var/lib/csb1-docker/` structure
  - Update docker-compose commands (still work due to legacy symlink)
  - Note: configs now version controlled

### 6. Cleanup

- [ ] Remove old docker directory if everything works:
  ```bash
  # This is now a symlink, so just verify
  ssh mba@cs1.barta.cm -p 2222 "readlink ~/docker"
  ```
- [ ] Remove backup files after verification:
  ```bash
  ssh mba@cs1.barta.cm -p 2222 "rm ~/docker-backup-*.tar.gz"
  ```

## Files to Create/Update

- `hosts/csb1/docker/docker-compose.yml` → CREATE from csb1 server
- `hosts/csb1/docker/traefik/static.yml` → CREATE from csb1 server
- `hosts/csb1/docker/traefik/dynamic.yml` → CREATE from csb1 server
- `hosts/csb1/docker/restic-cron/*` → CREATE from csb1 server
- `hosts/csb1/configuration.nix` → UPDATE with tmpfiles rules
- `hosts/csb1/README.md` → UPDATE documentation
- `hosts/csb1/docs/RUNBOOK.md` → UPDATE procedures

## Benefits

- ✅ Infrastructure as code (version controlled)
- ✅ Disaster recovery capability
- ✅ Change tracking and rollback
- ✅ Consistency with csb0 pattern
- ✅ Proper separation: immutable config vs mutable state
- ✅ Declarative management (no manual symlinks)

## Priority

P4 (High) - Critical infrastructure should be version controlled

## Effort

Medium (2-3 hours) - Copy files, update config, test thoroughly

## Dependencies

- P6400 completed (token rotation done)
- csb1 accessible via SSH
- Docker services stable

## Origin

Identified during P6400 token rotation work (2026-01-17). csb0 was refactored to proper structure, csb1 needs same treatment.

## References

- csb0 implementation: `hosts/csb0/configuration.nix` (lines 112-139)
- Pattern established in: commit 087e78ec "refactor(csb0): proper docker directory structure"
