# JoeDesk deployment (csb0)

The application now lives in https://github.com/markus-barta/joedesk. The
`joedesk` flake input pins its complete Docker build context; `configuration.nix`
overrides only the existing `joe-board` service build path with that store source.
The Compose spec retains OAuth, inbox routing, the push-token mount and real data
volume. HostDash is independently pinned for service navigation.

Do not edit application files here. Publish a reviewed JoeDesk release, update
only the `joedesk` input, switch csb0, then rebuild/recreate `joe-board` using the
rendered Compose spec under `/run/lock/compose-csb0.lock`. Keep the previous
image and NixOS generation until browser/data checks pass. Rollback selects that
previous generation and exact image; never overwrite the live history volume.

See `SECURITY.md` for deployment trust boundaries and producer responsibilities.
