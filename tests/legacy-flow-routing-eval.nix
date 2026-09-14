import ../hosts/csb1/legacy-flow-routing.nix {
  # Test-only RFC1918 addresses; these do not select production topology.
  privateSourceRanges = {
    pharos = [ "10.0.0.10/32" ];
    janus = [ "10.0.0.20/32" ];
  };
}
