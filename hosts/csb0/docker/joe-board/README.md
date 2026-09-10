# JoeDesk deployment (csb0)

The application now lives in https://github.com/markus-barta/joedesk. The
`joedesk` flake input pins its complete Docker build context; `configuration.nix`
overrides only the existing `joe-board` service with that store source, a
source-revision image name, and a build-only pull policy. The weekly updater
also excludes this host-built image from registry pulls.
The Compose spec retains OAuth, inbox routing, the push-token mount and real data
volume. HostDash is independently pinned for service navigation.

Do not edit application files here. Publish a reviewed JoeDesk release and
update only the `joedesk` input. After merge, deploy on csb0 with a fast-forward
Git pull followed by `just switch`. The existing compose unit owns
`/run/lock/compose-csb0.lock` and its configured post-recreate sequence; do not
run raw Compose commands or wrap the switch in another `flock`. Keep the
previous image and NixOS generation until browser/data checks pass. Rollback
selects that previous generation and exact image; never overwrite the live
history volume.

See `SECURITY.md` for deployment trust boundaries and producer responsibilities.
