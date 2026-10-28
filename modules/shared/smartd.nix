# SMART disk-health monitoring for physical fleet hosts — OPS-485.
#
# The 2026-10-28 fleet health check found no SMART signal on any Linux host:
# smartmontools was not installed anywhere, so a failing SSD would have shown up
# only as I/O errors or a failed monthly scrub. smartd watches every disk it
# can autodetect (DEVICESCAN) and logs attribute changes and failures to the
# journal; `smartctl -H /dev/sdX` gives an on-demand verdict.
#
# Import this only on bare-metal hosts. Cloud VMs (csb0, csb1) have virtual
# disks without SMART, and smartd fails to start when it finds no device at all.
# Disks behind USB bridges are monitored only where the bridge passes SMART
# through; smartd skips the others with a warning and keeps running.
{ pkgs, ... }:
{
  services.smartd = {
    enable = true;
    autodetect = true;
  };
  environment.systemPackages = [ pkgs.smartmontools ];
}
