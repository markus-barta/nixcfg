# JoeDesk deployment (csb0)

The application now lives in https://github.com/markus-barta/joedesk. The
`joedesk` flake input pins its complete Docker build context; `configuration.nix`
overrides only the existing `joe-board` service with that store source, a
source-revision image name, and a build-only pull policy. The weekly updater
also excludes this host-built image from registry pulls.
The Compose spec retains OAuth, inbox routing, the push-token mount and real data
volume. HostDash is independently pinned for service navigation.

Do not edit application files here. Publish a reviewed JoeDesk release and
update the `joedesk` input and the matching declarative release set in one reviewed commit. After merge, deploy on csb0 with a fast-forward
Git pull followed by `just switch`. The existing compose unit owns
`/run/lock/compose-csb0.lock` and its configured post-recreate sequence; do not
run raw Compose commands or wrap the switch in another `flock`. Keep the
previous image and NixOS generation until browser/data checks pass. Rollback
selects that previous generation and exact image; never overwrite the live
history volume.

See `SECURITY.md` for deployment trust boundaries and producer responsibilities.

## OPS-354 routing preparation

The exact `/joe/healthz` GET/HEAD router has priority 400 and no SSO. The
legacy db621bf board has no such endpoint: a 404 is expected until the approved
v2 switch and never counts as a passed v2 smoke. `/joe/healthz/`,
`/joe/healthz-extra`, UI, assets and all six reads stay behind SSO.
`joe-identity-strip-csb0` removes client `X-Auth-Request-User`,
`X-Auth-Request-Email` and `X-Forwarded-User` before forwardAuth; its
`authResponseHeaders` inject the authenticated user/email. Health and inbox
also strip identity. No host port is published. The edge never manipulates
`X-JoeDesk-Origin`. Static gate: `python3 tests/T76-joe-slash-routing.py`
(`--labels-only` omits full flake evaluation).

After the approved v2 switch, run T76 with `--live --joedesk-source SOURCE`.
It checks no-cookie GET/HEAD health and calls the exact source's
`scripts/smoke-release.mjs` for its full metadata/freshness/anonymous/spoof
matrix. Health redirects mean `auth_required`; protected denials must carry
no app-origin stamp. Use no production credentials in this check.

## One compatible release set

`hosts/csb0/joedesk-release.json` is shared by csb0, the hsb0 pusher and
executor. `active = v2` (OPS-354 activation) selects 040d6756 (sequence 27, JOED-59) with the r18b
pusher/executor pins (JOED-57 gateway heartbeat, after JOED-39 r18a); `current` retains db621bf, legacy `calendar`
26.09.21.12.00, sequence 23, no release tag. v1 has neither contracts.json nor
public `/joe/healthz`. Pusher and executor record their nixcfg source commits,
source trees and existing runtime image. The current downstream pins match
main 096cc37f (#1063, including #1061/#1062) and its live OPS-404 r16d switch-set image; `previous` preserves the
earlier flat-net runtime and the same legacy board. Preserve that rollback
history when promoting v2. Exact image IDs, NixOS
generations and verified private backup coordinates belong in the private
operator rollback record; null generation fields are outstanding evidence.

The active `v2` set records main 040d6756 (merge of PR #70, JOED-59; supersedes 6eacd6c7 / sequence 26 and d36b5295 / sequence 25), CalVer3
261021083537.0.0, sequence 27 from that checkout's `release.json` and
`release/preparation.json` (JOED-59 preparation; JOED-58 was the previous release set) and the complete exact `release/contracts.json`
record at manifest revision 9. The full source/tree and contract hashes are in
the RUNBOOK. Its downstream deployment pins are `v2.pusher`/`v2.executor` in the release set (JOED-57 after JOED-39 r18a; image `household-v2-switch-set-r18b-202610211147`). Fixtures do not
establish JOED-20 compatibility. In one approved cutover commit, record the
published board rev/image, final digest/IDs and approved immutable pusher and
executor pins, update flake URL/lock, select the complete compatible v2 set,
and retain `previous = db621bf set`. Never pin rebuild/v2 or fabricate a tag.
JOED-26 live adoption remains gated; current legacy metadata stays intact.
The published source's `release.json` still says candidate; OPS uses the exact
040d6756 commit and revision-9 contract hashes rather than treating that field as activation.

`python3 tests/T100-joedesk-release.py --prove-current --joedesk-source SOURCE`
proves the csb0 static spec against ed5e43d6 (routing held constant) and
hsb0 against main 096cc37f: image, full Compose spec, executor service, units,
firewall, users and real source derivation paths. The hsb0 evaluator uses a
disposable local Nix store, evaluates Linux packages and never builds. OPS
must also compare Linux `config.system.build.toplevel.drvPath` on the states
before/after the release-set item, with the routing item applied to both.
This is evaluation only; do not build a NixOS configuration on macOS.

## Rehearsal and rollback

Use `just rehearse-joedesk SOURCE --dry-run` to print the named-volume data
command plan and run T101's actual offline backup, verification, migration,
shared forward/rollback swaps and recovery guards without Docker. Ownership
on the Linux volume remains pending. `just rehearse-joedesk SOURCE` builds the
exact v1/v2 images, uses extracted Traefik v3 rules with a stub forwardAuth,
runs upstream forward smoke and signed-in spoof actor replacement, then
checks exact-image v1 rollback with private probes and authenticated reads.
It refuses fleet lab hosts and remote Docker contexts. Fixtures and their
fixed receipt clock prove lab behavior only. Output is value-free; private
source inputs/images are retained. Mutable synthetic data and every swap
sibling live in a per-run `ops354-<uuid>-data` Docker named volume: helpers
mount it at `/lab`, and both board images at `/var/lib`. Fixtures are seeded
through a helper from read-only host inputs. Backup reads and strict
1000:1000 / 0700/0600 checks run inside containers, avoiding macOS bind-mount
ownership emulation. The run removes only its own volume in `finally`,
including on failure; host store paths are never mounted.

The production procedure and required private rollback record are in
`hosts/csb0/docs/RUNBOOK.md`, OPS-354 sections. `just rollback-joedesk` on csb0
selects the recorded compatible previous set through a separately reviewed
rollback commit and normal `just switch`; it restores the verified v1 backup
into a new sibling, then calls `scripts/joedesk-data-swap.mjs` for ownership,
0700/0600 modes, same-filesystem rename and failure recovery. That same script
provides the forward swap used by the lab and cutover runbook. Stop all
writers first; the activation script's chown of the fixed store does not
prepare staged directories. Retain the unique old sibling, backup, exact
image tags/IDs, NixOS generations and v2 preparation source. The previous
selector uses declarative `pull_policy = never` to retain the old image.

The command prompts y/N at each action and prints cross-host commands for
hsb0; it never SSHs. Its legacy smoke uses private `/healthz` and `/readyz`,
the exact retained image/release and authenticated public v1 version/data
checks against the matching backup. New-smoke 404s never establish rollback.

## Production host gate

P1's gate is the actual `isCanonicalJoeHost` in legacy `public/joe/joe.js`;
P3 moved it to `public/joe/host.js`, imported by `app.js`.
`tests/T102-joedesk-host-gate.mjs --joedesk-source SOURCE` executes those real
functions from Git objects at the active/previous/candidate pins and checks
that the app invokes them. It requires `cs0.barta.cm` and its uppercase form,
and rejects foreign/suffix lookalikes. This is the browser privacy stub,
not a network/auth boundary; it adds no route exemption. Run
`just test-joedesk SOURCE` before review and the full T76 flake gate on Linux.
The rehearsal also requires this host gate before it creates lab artifacts.

### Separate Results ingress (OPS-354 item 5) — live since 2026-10-21

OPS-354 item 5 deliberately exceeds README P6b item 4. It went live with the OPS-354
cut-over on 2026-10-21 (a token-less POST answers 401) and is the JOED-39 Results producer's
target. The live board 040d6756 (sequence 27; like 6eacd6c7 and d36b5295 before it)
includes JOED-27's merged ingress implementation (b323c0a).
The proposed exact `/joe/inbox/results` router uses identity stripping and
app-level Bearer checking, without SSO. It does not use PathPrefix. T76 tests
the exact route, priority and strip-only chain, while `/joe/inbox/results/`
and `/joe/inbox/resultsx` still require SSO, including anonymous/spoofed live
GET/HEAD/POST probes. Source publication does not establish producer/results
sign-off, OPS rehearsal or permission to activate this infrastructure proposal.
