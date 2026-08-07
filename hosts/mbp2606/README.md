# mbp0

Private Apple Silicon M5 Max MacBook Pro for Markus.

This is a new physical device, provisioned from the retired M5 portable
profile with carried-forward key material by intent. It is not a former-work
work host.

## Profile

- Home Manager config: `homeConfigurations."mba@mbp0"`
- User: `mba`
- Architecture: `aarch64-darwin`
- Theme: `lightGray`
- Agent secrets root: `secrets/agents/host/mbp0`

## Notes

- `inspr.git.atelier.personal` is **disabled** since NIX-216 (m5 userkey
  retired 2026-07; remotes rewritten to HTTPS).
- `inspr.git.atelier.bytepoets` (former work context) is disabled for this private machine.
- The `m5-*` key names are retained because the material was deliberately
  carried forward.

## Inbound SSH (declarative)

Since 2026-07-04 (NIX-215) `~/.ssh/authorized_keys` is managed by
`inspr.ssh.authorized` (marker-block render; lines outside the block are
preserved but unmanaged — audit ticket exists for those). Trust preset:
`personalHosts` from `modules/shared/ssh-keyring.nix`. Admits
`markus@mbp2607` for the mbp2607 → mbp0 workflow.

## Apply

```bash
nix run home-manager -- switch --flake ".#mba@mbp0"
```
