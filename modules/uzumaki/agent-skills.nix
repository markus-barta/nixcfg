# agent-skills.nix — declarative installation of agent skills, all harnesses
#
# Thin consumer of inspr-modules' `homeManagerModules.agent-skills`: each
# skill is declared ONCE here and rendered into every configured harness
# skills path — ~/.claude/skills/ AND ~/.codex/skills/ — as read-only
# symlinks into /nix/store. Both harnesses scan their path at session
# startup and load SKILL.md frontmatter; once linked the skill is
# invokable as /<name> (Claude Code) or $<name> (Codex).
#
# Successor to claude-skills.nix (Claude-only, upstream pins only) and to
# the imperative ~/.agents/skills symlink farm it replaced: same declarative
# rationale (identical skill set on every Mac that switches against this
# flake, pinned sources, no silent drift), now harness-agnostic.
#
# SKILL SOURCES:
#   - INSPR-authored skills (ship-next, housekeeping) ship bundled with the
#     inspr-modules flake input; naming them with no `source` uses that copy.
#     Update: edit in ~/Code/inspr-modules, push, `nix flake update
#     inspr-modules`, switch.
#   - Upstream skills stay pinned here via fetchFromGitHub, exactly like
#     claude-skills.nix did.
#
# HOW TO ADD AN UPSTREAM SKILL:
#   1. Find the skill (a dir with SKILL.md at its root), e.g. in
#      github.com/anthropics/skills/skills/<name>/.
#   2. From an already-pinned source: add a `skills.<name>.source` entry
#      below. New repo: add another fetchFromGitHub pin. Get the sha via:
#        nix run nixpkgs#nix-prefetch-github -- <owner> <repo> --rev <rev>
#
# HOW TO BUMP AN EXISTING PIN:
#   1. Find the new commit on the upstream repo's main branch.
#   2. Update `rev` here, change `sha256` to a fake (e.g. lib.fakeHash).
#   3. `just safe-switch` — Nix prints the actual hash in the error.
#   4. Paste the real hash, re-switch.
#
# Pin freshness audit: see the trailing comment on each fetchFromGitHub for
# the date the rev was captured.

{
  pkgs,
  inputs,
  ...
}:

let
  anthropicSkills = pkgs.fetchFromGitHub {
    owner = "anthropics";
    repo = "skills";
    rev = "f458cee31a7577a47ba0c9a101976fa599385174"; # 2026-05-09
    sha256 = "sha256-jKNYFom6R+Qw7LQ8vFPBe51JpqIP0tTSY8LM4aPlnT4=";
  };
in
{
  imports = [ inputs.inspr-modules.homeManagerModules.agent-skills ];

  # Curate per-host or per-user by editing this set. Skills are cheap (MD +
  # assets); err on the side of including ones you might want, but don't
  # dump whole catalogs (each harness scans + holds frontmatter in memory
  # for every entry at session start).
  inspr.agent-skills = {
    enable = true;

    skills = {
      # ── INSPR-bundled (source defaults to the inspr-modules copy) ─────
      ship-next = { }; # propose + deliver the single right next change
      housekeeping = { }; # hygiene sweep → codesweep → challenge → PPM → report
      tidyrepo = { }; # cheap state-only pass below housekeeping (no codesweep, no challenge)
      product-gauntlet = { }; # multi-agent delivery: decompose → route → worktree → QA on parity
      design-frontier-gauntlet = { }; # five isolated visual concepts → local comparison gallery

      # ── Pinned upstream: anthropics/skills ────────────────────────────
      frontend-design = {
        # bold/distinctive web design (avoid AI-default look)
        source = "${anthropicSkills}/skills/frontend-design";
        harnesses = [ "claude" ]; # unchanged from claude-skills.nix; Codex opt-in when wanted
      };
    };
  };
}
