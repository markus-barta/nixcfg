# mbp0

Private Apple Silicon M5 Max MacBook Pro for Markus.

This is a new physical device, provisioned from the retired M5 portable
profile with carried-forward key material by intent. It is not a BYTEPOETS
work host.

## Profile

- Home Manager config: `homeConfigurations."mba@mbp0"`
- User: `mba`
- Architecture: `aarch64-darwin`
- Theme: `lightGray`
- Agent secrets root: `secrets/agents/host/mbp0`

## Notes

- `inspr.git.atelier.personal` remains enabled.
- `inspr.git.atelier.bytepoets` is disabled for this private machine.
- The `m5-*` key names are retained because the material was deliberately
  carried forward.

## Apply

```bash
nix run home-manager -- switch --flake ".#mba@mbp0"
```
