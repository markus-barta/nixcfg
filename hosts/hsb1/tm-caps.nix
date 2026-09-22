# Time Machine caps — the ONE place the numbers live (OPS-226).
#
# Consumed by tm-pool.nix (documents the imperative `zfs set`, asserts the
# pairing at eval time), tm-samba.nix (`fruit:time machine max size`) and
# tm-watch.nix (the witness validates the live ZFS caps against these).
#
# Per user, all in GiB (binary), so `zfs set …G` and Samba's `…G` mean the
# same bytes:
#   refquotaG — what Time Machine may *reference*: TM's own cap. Samba must
#               advertise LESS than this (maxSizeG), so TM thins its old
#               backups while ZFS still accepts writes. TM fills whatever it
#               is given by design; referenced ≈ refquota is steady state.
#   quotaG    — hard cap INCLUDING sanoid snapshots. quota − refquota is the
#               snapshot budget; tm-watch prunes autosnap_* (oldest first, the
#               newest last) when the headroom under quota drops below 150G.
#               Limits: pruning frees only blocks no remaining snapshot holds,
#               and a write burst > 150G within one 10-minute poll still hits
#               ENOSPC — then tm-watch pages `headroom` and quota must be
#               raised by hand (there is pool slop for that).
#   maxSizeG  — Samba `fruit:time machine max size`. ≥ 32G under refquotaG
#               (asserted): Samba's free-space arithmetic is approximate
#               (max size − bands × band size) and a band is 625 MiB here.
#
# SIZING RULE (OPS-228): Time Machine's own cap must be ≥ 2× the Mac's data.
# TM never deletes the latest backup, and now and then it decides on a full
# re-copy (interrupted session, periodic verification); with 1.6T of data on
# a 2.2T cap that re-copy needs 1.6T free next to a 1.5T latest backup —
# impossible → "Backup-Volume ist voll" on 2026-09-22 15:42 despite OPS-226.
# mbp2607 holds ~1.6T → 3.55T cap; mbp2606 holds ~0.4T → 1T cap.
#
# Live commands after changing a number (both caps are imperative, never
# disko-declared — see tm-pool.nix):
#   zfs set refquota=3600G quota=3900G tm/markus
#   zfs set refquota=1024G quota=1300G tm/mailina
#
# 3900G + 1300G = 5200G ≈ 5.1T of the pool's ~5.45TiB usable; the rest is slop.
{
  markus = {
    dataset = "tm/markus";
    path = "/srv/tm/markus";
    refquotaG = 3600; # ≈ 3.5T — ≥ 2× the Mac's ~1.6T of data
    quotaG = 3900; # 300G snapshot budget → sanoid keeps 3 dailies (tm-pool.nix)
    maxSizeG = 3550;
  };
  mailina = {
    dataset = "tm/mailina";
    path = "/srv/tm/mailina";
    refquotaG = 1024; # 1T — ≥ 2× the Mac's ~0.4T of data
    quotaG = 1300; # 276G snapshot budget → 7 dailies
    maxSizeG = 1000;
  };
}
