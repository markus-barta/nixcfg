# Use the same nixpkgs revision as the hosts, on Linux and Darwin CI runners.
let
  locked = (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes.nixpkgs.locked;
  source = builtins.fetchTarball {
    url = "https://github.com/${locked.owner}/${locked.repo}/archive/${locked.rev}.tar.gz";
    sha256 = locked.narHash;
  };
  pkgs = import source { };
in
pkgs.mkShell {
  packages = with pkgs; [
    bash
    fish
    starship
    coreutils
    shellcheck
    (python3.withPackages (ps: [
      ps.pyte
      ps.wcwidth
    ]))
  ];
}
