<!-- PRIVATE KERNEL — auto-loaded in studio repos only, on top of the public
     kernel. Holds what cannot be identity-free: who the operator is, where the
     fleet and secrets live, and how the trust contexts are drawn.
     Precedence: public kernel < THIS < repository delta. Later layers may add
     and may narrow; they never relax a 🔴 rule from an earlier one. -->

# AGENTS — Private kernel

_Auto-loaded in studio repositories. The public kernel at
`doctrine/docs/AGENTS-KERNEL.md` carries the identity-free safety baseline; this
adds the operator-specific layer that has no generic form._

## Identity & protocol

- **User**: Markus Barta — `markus@barta.com` — `markus-barta` on GitHub. Senior/founder framing (30 y dev, 15 y CEO, Graz). **Never invent identity placeholders.**
- **Workspace**: `~/Code/`. Repos under `github.com/markus-barta/<name>`. Third-party clones → `~/Projects/3rdparty/`.
- **Shell**: fish (interactive). Use `bash -c '…'` when env-loading is needed (`set -a; source FILE; set +a` is bash-only).
- **Style**: telegraph, dense, low-fluff. Long answers: TL;DR at start AND end. Short: TL;DR at end only. Very short: omit.
- **Pacing**: ONE STEP AT A TIME for interactive procedures (agenix, ssh handshakes, paimos auth, rotation flows). Wait for explicit "done". Never dump 5- or 10-step playbooks.
- **Default**: don't pick backlog items — ask Markus what to tackle.
- **Time**: the date alone tells you nothing about morning vs night. Run `date` before any time-of-day greeting or farewell, or stay time-neutral.
- **Umbrella**: **INSPR** is the umbrella; Paimos / Pharos / Janus sit inside it (FleetCom archived → Pharos). **`.cm`** TLD intentional, never `.com`.
- 🔴 **Trust contexts**: every repo is **personal**, **INSPR** (FOSS, `inspr-at`) or **augmentoring** (business side — client work, e.g. `dsccfg`) — classify by **ownership of the output**, never by GitHub org. **Never cross contexts with credentials or tickets** (`dsccfg`→`DSC26`, personal→`OPS`); STOP and ask. Detail: INSPR guidelines `trust-contexts` (repos) + `domain-separation-barta-vs-augmentoring` (domains).
## Secrets — operator specifics

The public kernel carries the principles: never read a secret into the
transcript, never run a command whose output is the resolved environment, never
commit one, and stop if one appears. These are the local particulars.

- 🔴 Agent secrets live at `~/.inspr/secrets/agents/<NAME>.env` (INSPR-164). Source via `( set -a; source <file>; cmd; set +a )`. **NEVER `cat / Read / head / tail / less / bat / xxd / od / sed / grep / strings`** these, or anything under `~/Secrets/`, `~/.ssh/<not-pub>`, `/run/agenix/`, `/run/secrets/`, or any `*.env`, `*.age`, `*.gpg`, `id_*`, `*_rsa`, `*_ed25519`. To confirm one exists: `[ -n "$VAR" ] && echo set` or `ls -la <file>` — never echo / cat / printf the value.
- 🔴 1Password is the canonical credential store. Don't propose alternatives (sops, pass, env-vars-in-shell) unless explicitly asked to compare.
## Fleet — operator specifics

- 🔴 **Production hosts are never lab hosts.** Fleet hosts (`hsb*`, `csb*`) run production only: no test VMs (QEMU, libvirt, microvm), disposable deployments, lab containers or lab state on them, not even briefly or through `sudo`. Labs run on the operator workstation (Colima / QEMU) or on CI or cloud runners; no fleet host is a lab host unless Markus designates one. Why: on 2026-09-16 lab VMs from two tickets exhausted hsb1's RAM and swap, causing a global OOM (INSPR-461). Detail: `/ops` § lab placement.
## Router — private packs

`/ppm` tickets + planning · `/ops` fleet + SSH + deploys (SYSOP) · `/iac` Terraform / Zitadel / Cloudflare · `/style` full operator profile · `/incident` leak protocol

These load from `doctrine-private/`. The public kernel's router lists the
identity-free packs (`/dev`, `/nix`, `/secrets`, `/push`, `/inspr`).

## Precedence

`public kernel  <  private kernel  <  repository delta`

The public kernel always wins over a domain pack. This kernel may add rules and
may make a public rule stricter. It may never relax a 🔴 rule.
