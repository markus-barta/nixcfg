<!--
  Layered doctrine loader for Claude Code.

  POST-PHASE-6 (INSPR-189, 2026-05-15):
  Auto-loaded doctrine = KERNEL only + nixcfg-specific delta. All deeper
  context (git workflow, secrets pipeline, nix patterns, ops, ppm, full
  Markus profile) loads on demand via slash commands.

  Slash commands available:
    /inspr     — TL;DR map of all available commands + doctrine architecture
    /dev       — git workflow + tests + dev tooling (AGENTS-DOMAIN-DEV.md)
    /secrets   — agenix + 1P + env files (AGENTS-DOMAIN-SECRETS.md)
    /nix       — nix-darwin + HM + NixOS (AGENTS-DOMAIN-NIX.md)
    /ops       — fleet ops + SSH (AGENTS-DOMAIN-OPS.md + SYSOP role)
    /ppm       — paimos + tickets (AGENTS-DOMAIN-PPM.md + PPM role)
    /style     — full Markus profile (AGENTS-PROFILE-MARKUS.md)
    /incident  — security incident / leak protocol
    /push, /pushall, /ocbots, /modelhelp, /oc-modelupdate — existing helpers

  Doctrine source: github.com/markus-barta/inspr-modules vendored as
  ./doctrine git submodule; bump with `git submodule update --remote doctrine`.

  Pre-Phase-6 budget: ~127k chars auto-loaded. Post-Phase-6: ≤25k.
-->

@./doctrine/docs/AGENTS-KERNEL.md
@./AGENTS.md
