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

## State of secret-dependent modules

`inspr.secrets.agents`, `inspr.paimos-cli`, and `inspr.git.atelier.*` are gated
**off** in `home.nix` until this host's SSH keys exist and are registered as
agenix recipients (NIX-215 checklist). Flip them on in a follow-up commit after
the rekey. `atelier.bytepoets` stays off permanently (BYTEPOETS history).
