# mbp2607 — MacBook Pro (Markus)

| Fact         | Value                                                             |
| ------------ | ----------------------------------------------------------------- |
| Commissioned | 2026-07 (first host on the YYMM scheme — see PPM KB below)        |
| Hardware     | Apple Silicon MacBook Pro (high-RAM successor to mbp0)            |
| User         | `markus` (first non-`mba` host; `mba` retired for new machines)   |
| Config       | Home Manager only: `home-manager switch --flake .#markus@mbp2607` |
| Theme        | teal (`theme-palettes.nix`)                                       |
| Network      | DHCP for now; fixed IP planned via hsb0 DHCP reservation          |

## Provenance

Fresh start by design — **no key material or config carried over from mbp0**.
Items get pulled from mbp0 individually when actually missed, never wholesale.

- Naming scheme: PPM Knowledge `NIX / guideline / host-naming-scheme`
- Commissioning ticket + provisioning log: **NIX-215** (epic NIX-214)

## State of workstation modules

`inspr.secrets.agents`, `inspr.paimos-cli`, and `inspr.git.atelier.personal`
are **on** since 2026-07-03 (host keys registered as agenix recipients,
`mbp2607-personal-userkey` minted — NIX-215). `atelier.bytepoets` stays off
permanently (former-work history). `inspr.paimos-cli` manages non-secret routing
only; authentication is an interactive OS-keyring login.

## Keyboard & input tools (2026-07-04, NIX-215)

- **Karabiner-Elements**: app via Brewfile baseline (`just bundle`); JSON
  config Nix-managed fleet-wide (`modules/config/karabiner.json` →
  `~/.config/karabiner/`). Input Monitoring granted manually.
- **BetterTouchTool**: cask in `extraCasks`; settings + license are **not**
  Nix-managed. One-shot migration from mbp0 (2026-07-04): rsync of
  `~/Library/Application Support/BetterTouchTool/` (incl.
  `bettertouchtool.bttlicense`) + `defaults export/import` of the prefs
  domain. Changes since then live only in BTT's own data store.
- **SSH identity**: `~/.ssh/id_ed25519` (`markus@mbp2607`, in ssh-keyring
  `personalHosts`; 1Password backup "mbp2607 id_ed25519"). Distinct from the
  atelier `mbp2607-personal-userkey` (git only) — deliberate separation.
