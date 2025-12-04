# gpc0 Test Suite

Tests for Gaming PC 0 (gpc0) - NixOS desktop with gaming support.

## Test Categories

| Test                  | Description                   | Runs On         |
| --------------------- | ----------------------------- | --------------- |
| T00-nixos-base.sh     | NixOS system basics           | Remote (SSH)    |
| T01-theme.sh          | Theme module (purple palette) | Local (on host) |
| T02-uzumaki-fish.sh   | Fish functions from uzumaki   | Local (on host) |
| T03-stasysmo.sh       | System metrics daemon         | Local (on host) |
| T10-desktop-plasma.sh | KDE Plasma integration        | Local (on host) |
| T11-gaming.sh         | Gaming packages & drivers     | Local (on host) |

## Running Tests

### All Tests (from gpc0)

```bash
cd ~/nixcfg/hosts/gpc0/tests
./run-all-tests.sh
```

### Single Test

```bash
./T01-theme.sh
```

### Remote Tests (from workstation)

```bash
export GPC0_HOST=192.168.1.154
./T00-nixos-base.sh
```

## Theme: Purple (Gaming)

gpc0 uses the **purple** palette from `modules/shared/theme-palettes.nix`:

- Category: Gaming
- Primary color: `#9868d0` (vibrant purple)
- Lightest: `#d0b8e8` (lavender)
- Darkest: `#140c20` (near black with purple tint)
