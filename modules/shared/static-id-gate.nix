# Static uid/gid collision gate — NIX-354.
#
# WHY THIS EXISTS
# ===============
# On 2026-07-04 the nixpkgs 26.11 bump let fish's man-completion support start
# a runtime man-cache service, whose `mandb` user got gid 992 from the dynamic
# allocator (descending from 999). Three weeks later csb1 declared
# users.groups.pharos-container.gid = 992 statically — and NixOS applied it
# without checking the id was already taken, silently leaving TWO names on one
# gid. Group-name resolution became ambiguous, and any group-992 read bit
# admitted the mandb user. Found live 2026-08-12 during the NIX-353 secret
# sweep; nothing in eval, build, or activation had said a word.
#
# WHAT THIS DOES
# ==============
# 1. Eval-time assertion: no two DECLARED static ids may collide (cheap, pure).
# 2. Activation-time gate, ordered right after the users/groups update: if
#    /etc/passwd or /etc/group ends up with two names on one id — whatever the
#    source: a later static declaration, an id-map reuse after a user returns,
#    a manual mutation — the activation FAILS loudly before services start,
#    instead of shipping an ambiguous id space. The 2026-07-25 switch that
#    created the csb1 collision would have failed on the spot.
#
# Remediation guidance lives in the failure message; the incident trail is in
# PPM NIX-354.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  staticUids = lib.filterAttrs (_: u: u.uid != null) config.users.users;
  staticGids = lib.filterAttrs (_: g: g.gid != null) config.users.groups;

  dupDeclared =
    attrs: idOf:
    let
      byId = lib.foldlAttrs (
        acc: name: v:
        acc // { ${toString (idOf v)} = (acc.${toString (idOf v)} or [ ]) ++ [ name ]; }
      ) { } attrs;
    in
    lib.filterAttrs (_: names: lib.length names > 1) byId;

  dupStaticUids = dupDeclared staticUids (u: u.uid);
  dupStaticGids = dupDeclared staticGids (g: g.gid);

  describe =
    dups:
    lib.concatStringsSep "; " (
      lib.mapAttrsToList (id: names: "${id} -> ${lib.concatStringsSep ", " names}") dups
    );
in
{
  assertions = [
    {
      assertion = dupStaticUids == { };
      message = "static-id-gate: two declared users share a uid: ${describe dupStaticUids} (NIX-354).";
    }
    {
      assertion = dupStaticGids == { };
      message = "static-id-gate: two declared groups share a gid: ${describe dupStaticGids} (NIX-354).";
    }
  ];

  # Runs AFTER update-users-groups so it judges the id space this generation
  # actually ships. A failure aborts activation before services restart; the
  # operator fixes the duplicate (usually: remove or re-pin the squatter, see
  # NIX-354) and re-runs the switch.
  system.activationScripts.staticIdCollisionGate = {
    deps = [ "users" ];
    text = ''
      _nix354_dups="$(
        ${pkgs.gawk}/bin/awk -F: '{ n[$3] = n[$3] " " $1 } END { for (id in n) { c = split(n[id], a, " "); if (c > 1) printf "uid %s:%s\n", id, n[id] } }' /etc/passwd
        ${pkgs.gawk}/bin/awk -F: '{ n[$3] = n[$3] " " $1 } END { for (id in n) { c = split(n[id], a, " "); if (c > 1) printf "gid %s:%s\n", id, n[id] } }' /etc/group
      )"
      if [ -n "$_nix354_dups" ]; then
        echo "static-id-gate: REFUSING to finish activation — duplicate ids in the live user database (NIX-354):" >&2
        echo "$_nix354_dups" >&2
        echo "static-id-gate: two names on one id make ownership and group bits ambiguous." >&2
        echo "static-id-gate: remove or re-pin the unintended holder, then re-run the switch." >&2
        exit 1
      fi
    '';
  };
}
