{
  inputs = {
    nixpkgs.url = "path:@NIXPKGS@";
    disko = {
      url = "path:@DISKO@";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      disko,
      ...
    }:
    {
      runtime = builtins.fromJSON (builtins.readFile ./runtime.json);
      nixosConfigurations.managed = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit runtime; };
        modules = [
          disko.nixosModules.disko
          ./configuration.nix
          ./disk-config.nix
        ];
      };
    };
}
