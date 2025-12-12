# 2025-12-08 - Whitelist Roborock Vacuum Domains

## Description

The Roborock vacuum (192.168.1.235 / roborock-vacuum-a226) needs specific domains whitelisted in AdGuard Home to function properly with cloud connectivity.

## Source

- AdGuard Home query log: http://192.168.1.99:3000/#logs?response_status=all&search=%22192.168.1.235%22

## Scope

Applies to: AdGuard Home on hsb8

## Domains to Whitelist

Extracted via: `ssh mba@192.168.1.99 "sudo grep '192.168.1.235' /var/lib/private/AdGuardHome/data/querylog.json | jq -r '.QH' | sort -u"`

| Domain                                                      | Purpose                      |
| ----------------------------------------------------------- | ---------------------------- |
| `mqtt-eu-3.roborock.com`                                    | MQTT broker                  |
| `api-eu.roborock.com`                                       | API endpoint                 |
| `eu-app.roborock.com`                                       | App backend                  |
| `euiot.roborock.com`                                        | IoT endpoint                 |
| `v-eu-2.roborock.com`                                       | Voice/firmware               |
| `v-eu-3.roborock.com`                                       | Voice/firmware               |
| `vivianspro-eu-1316693915.cos.eu-frankfurt.myqcloud.com`    | Tencent COS (maps)           |
| `conf-eu-1316693915.cos.eu-frankfurt.myqcloud.com`          | Tencent COS (config)         |
| `anonymousinfo-eu-1316693915.cos.eu-frankfurt.myqcloud.com` | Tencent COS (telemetry)      |
| `cdn.awsde0.fds.api.mi-img.com`                             | Xiaomi CDN (firmware/images) |

**Not whitelisted** (optional telemetry):
| `upl.baidu.com` | Baidu upload - likely non-essential telemetry |

## Acceptance Criteria

- [x] All three domains added to AdGuard Home allowlist (declaratively in configuration.nix)
- [ ] Roborock vacuum can communicate with cloud services (needs deploy + verify)
- [ ] App connectivity verified working (needs deploy + verify)

## Implementation

Added `dnsAllowlist` variable to `hosts/hsb8/configuration.nix` with AdGuard Home allowlist rules:

- Easy to see and edit in git
- Declarative - no UI changes needed
- Rules use AdGuard Home format: `@@||domain^`

Deploy with: `nixos-rebuild switch --flake .#hsb8`

## Notes

- These are EU endpoints (may differ for other regions)
- The myqcloud.com domain is Tencent Cloud Object Storage used by Roborock for maps/data
