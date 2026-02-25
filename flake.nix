{
  outputs =
    {
      self,
      ...
    }@inputs:
    let
      lib-nixpkgs = inputs.introducingbloats.lib.nixpkgs inputs;
    in
    {
      packages = lib-nixpkgs.forSystems lib-nixpkgs.linuxOnly (
        { pkgs, ... }:
        let
          package = pkgs.callPackage ./package.nix { };
        in
        {
          default = package;
          tracy = package;
          updateScript = pkgs.callPackage ./update.nix { };
        }
      );
    };
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11-small";
    introducingbloats.url = "github:introducingbloats/core.flakes/main";
  };
}
