# hsb1 Test Suite

Tests for Home Server Box 1 (hsb1) - NixOS server with home automation.

## Test Categories

| Test                   | Description                 | Runs On         |
| ---------------------- | --------------------------- | --------------- |
| T00-nixos-base.sh      | NixOS system basics         | Remote (SSH)    |
| T01-theme.sh           | Theme module (cyan palette) | Local (on host) |
| T02-uzumaki-fish.sh    | Fish functions from uzumaki | Local (on host) |
| T03-stasysmo.sh        | System metrics daemon       | Local (on host) |
| T04-docker-services.sh | Docker containers running   | Remote (SSH)    |

## Running Tests

### All Tests (from hsb1)

```bash
cd ~/nixcfg/hosts/hsb1/tests
./run-all-tests.sh
```

### Single Test

```bash
./T01-theme.sh
```

### Remote Tests (from workstation)

```bash
export HSB1_HOST=192.168.1.101
./T00-nixos-base.sh
```

## Theme: Cyan (Home Server)

hsb1 uses the **cyan** palette from `modules/shared/theme-palettes.nix`:

- Category: Home
- Primary color: `#68c8d0` (vibrant cyan)
- Lightest: `#b8e8e0` (pale cyan)
- Darkest: `#0c1820` (near black with cyan tint)

## Services Tested

- APC UPS daemon (apcupsd)
- MQTT volume control
- StaSysMo system metrics
- Docker containers (homeassistant, nodered, zigbee2mqtt, mosquitto, scrypted, etc.)
