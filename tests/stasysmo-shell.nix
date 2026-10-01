# Use the hosts' nixpkgs revision for Linux CI and local Darwin validation.
let
  locked = (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes.nixpkgs.locked;
  source = builtins.fetchTarball {
    url = "https://github.com/${locked.owner}/${locked.repo}/archive/${locked.rev}.tar.gz";
    sha256 = locked.narHash;
  };
  pkgs = import source { };
in
pkgs.mkShell {
  STASYSMO_TEST_INIT_JSON = pkgs.writeText "stasysmo-test-init.json" (
    builtins.toJSON (import ./stasysmo-init-eval.nix { inherit (pkgs) lib; })
  );
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
