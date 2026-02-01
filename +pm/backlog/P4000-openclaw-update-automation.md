# P4000: OpenClaw Update Automation

## Goal

Automate the manual process of updating the custom `openclaw` package. The current process requires manual hash calculation for both source and pnpm dependencies.

## Solution

A host-side script (`scripts/update-openclaw.sh`) designed to run on **hsb1** (Linux) from `~/Code/nixcfg`.

---

## Implementation Notes

### 1. Package Structure (Critical for sed patterns)

The `pkgs/openclaw/package.nix` uses this structure for platform-specific hashes:

```nix
pnpmDepsHash =
  if stdenvNoCC.hostPlatform.isDarwin then
    "sha256-DARWIN_HASH..."      # Line 27
  else
    "sha256-LINUX_HASH...";      # Line 29 <- TARGET
```

**The script targets line 29 specifically** using line-number-based sed. If the file structure changes significantly, the script will need updating.

### 2. Hash Discovery ("Probe Build")

The script:

1. Sets the Linux hash to a fake value (`sha256-AAA...`).
2. Runs `nix build .#openclaw --no-link`.
3. The build fails at the pnpm fetch phase with a hash mismatch.
4. The script extracts the "got:" hash from stderr.
5. It patches the file with the correct hash.

**Why `.#openclaw` and not `.#openclaw.pnpmDeps`?**
The `pnpmDeps` attribute isn't directly exposed in `flake.nix` `packages` output. Building the full package triggers the dependency fetch first, which is where the hash mismatch occurs.

### 3. Version 0.0.0 Bug

OpenClaw is a monorepo. The root `package.json` version is patched in `postPatch`, but sub-packages may have their own `package.json` files.

**Current `postPatch` patches all package.json files.** This fix is already applied in `pkgs/openclaw/package.nix` and should address the "0.0.0" issue.

```nix
postPatch = ''
  # Patch all package.json files in the monorepo
  find . -name "package.json" -type f | while read -r f; do
    jq '.version = "${finalAttrs.version}"' "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
  done
'';
```

**Status**: Applied. Verify after next update that the UI shows the correct version.

### 4. Darwin Hashes

The script **only updates Linux hashes**. Darwin hashes remain unchanged.

- This is intentional: `hsb1` is the only deployment target.
- If macOS builds are needed later, update manually or extend the script.

---

## Execution

```bash
# On hsb1
cd ~/Code/nixcfg
./scripts/update-openclaw.sh

# Then deploy
just switch
```

## Verification Checklist

- [ ] Script finds latest version from GitHub API
- [ ] Source hash calculated correctly via `nix-prefetch-url`
- [ ] Version string updated in `package.nix`
- [ ] Source hash updated in `fetchFromGitHub` block
- [ ] Linux pnpmDepsHash reset triggers probe build
- [ ] "got:" hash extracted from build error
- [ ] Final hash applied to correct line
- [ ] `just check-host hsb1` passes
- [ ] Git commit and push succeed

## Risks

| Risk                   | Mitigation                                                     |
| ---------------------- | -------------------------------------------------------------- |
| GitHub API rate limit  | Unlikely for occasional updates; add token if needed           |
| File structure changes | Script documents line numbers; update sed if structure changes |
| Darwin breaks          | Intentional; Darwin is secondary                               |
| Network issues         | Script fails fast with clear error messages                    |

## Future Improvements

- Add `just update-openclaw` recipe for convenience
- Expand `postPatch` if 0.0.0 bug confirmed
- Add optional version argument to script for pinning
