# claude-skills.nix — declarative installation of Claude Code skills
#
# Drops skill directories into ~/.claude/skills/<name>/ as read-only symlinks
# into /nix/store. Claude Code (and Claude Desktop) scan this path at session
# startup and load the SKILL.md frontmatter from each subdirectory; once linked
# the skill is invokable as /<name> in any session.
#
# WHY DECLARATIVE (vs. `npx skills add ...` or manual git clones):
#   - Same skill set on every Mac that switches against this flake.
#   - Pinned to specific commits — no silent drift if upstream rewrites.
#   - Visible in flake source, auditable, rollbackable like any other HM file.
#   - Skill update == bump rev + sha + switch. No imperative state.
#
# HOW TO ADD A SKILL:
#   1. Find the skill in github.com/anthropics/skills/skills/<name>/ (or any
#      other repo containing a SKILL.md at its root).
#   2. If it's from an already-pinned source, just add the name to that
#      source's `pick` list below.
#   3. If it's from a new repo, add a new `mkSkillsBundle` invocation with
#      the rev + sha. Get the sha via:
#        nix run nixpkgs#nix-prefetch-github -- <owner> <repo> --rev <rev>
#
# HOW TO BUMP AN EXISTING SOURCE:
#   1. Find the new commit on the upstream repo's main branch.
#   2. Update `rev` here, change `sha256` to a fake (e.g. lib.fakeHash).
#   3. `just safe-switch` — Nix prints the actual hash in the error.
#   4. Paste the real hash, re-switch.
#
# Pin freshness audit: see the trailing comment on each fetchFromGitHub for
# the date the rev was captured.

{
  lib,
  pkgs,
  ...
}:

let
  # ── 1. Pinned upstream skill bundles ──────────────────────────────────
  # Each fetchFromGitHub block pins a single repo at a known commit.
  # Add more by following the same shape; keep `rev` + `sha256` paired.

  anthropicSkills = pkgs.fetchFromGitHub {
    owner = "anthropics";
    repo = "skills";
    rev = "f458cee31a7577a47ba0c9a101976fa599385174"; # 2026-05-09
    sha256 = "sha256-jKNYFom6R+Qw7LQ8vFPBe51JpqIP0tTSY8LM4aPlnT4=";
  };

  # ── 2. mkSkillFiles helper ────────────────────────────────────────────
  # Given a fetched source + a list of skill names (subdirs under skills/),
  # produce home.file entries that materialize each at ~/.claude/skills/<name>.
  # The source root convention matches anthropics/skills (skills/<name>/);
  # for repos with a different layout, pass a custom subPath.
  mkSkillFiles =
    {
      src,
      pick,
      subPath ? "skills",
    }:
    lib.listToAttrs (
      map (name: {
        name = ".claude/skills/${name}";
        value.source = "${src}/${subPath}/${name}";
      }) pick
    );
in
{
  # ── 3. Wire the actual skill set ──────────────────────────────────────
  # Curate per-host or per-user by editing the `pick` list. Skills are
  # cheap (just MD + assets); err on the side of including ones you might
  # want, but don't dump the whole catalog (Claude scans + holds frontmatter
  # in memory for each at session start).
  home.file = mkSkillFiles {
    src = anthropicSkills;
    pick = [
      "frontend-design" # bold/distinctive web design (avoid AI-default look)
    ];
  };
}
