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
#               snapshot budget; tm-watch prunes the oldest autosnap_* when the
#               headroom under quota drops below 100G, so TM never meets ENOSPC.
#   maxSizeG  — Samba `fruit:time machine max size`. ≥ 32G under refquotaG
#               (asserted): Samba's free-space arithmetic is approximate
#               (max size − bands × band size) and a band is 625 MiB here.
#
# Live commands after changing a number (both caps are imperative, never
# disko-declared — see tm-pool.nix):
#   zfs set refquota=2253G quota=3277G tm/markus
#   zfs set refquota=1434G quota=2048G tm/mailina
#
# 3277G + 2048G = 5325G ≈ 5.2T of the pool's ~5.45TiB usable; the rest is slop.
{
  markus = {
    dataset = "tm/markus";
    path = "/srv/tm/markus";
    refquotaG = 2253; # ≈ 2.2T
    quotaG = 3277; # ≈ 3.2T → 1T snapshot budget (Sep 21 2026 churned ~560G in a day)
    maxSizeG = 2200;
  };
  mailina = {
    dataset = "tm/mailina";
    path = "/srv/tm/mailina";
    refquotaG = 1434; # ≈ 1.4T
    quotaG = 2048; # 2T → 0.6T snapshot budget
    maxSizeG = 1400;
  };
}
