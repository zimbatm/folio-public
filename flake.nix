{
  description = "Folio: an assistant for the reMarkable Paper Pro Move that can change itself";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        folio-server = import ./server { inherit pkgs; };
        folio-bridge = import ./bridge { inherit pkgs; };
        rmc = import ./server/rmc.nix { inherit pkgs; };
      });

      nixosModules.default = import ./nix/module.nix {
        folioPackages = system: self.packages.${system};
      };

      # evaluates a system with the module, so a broken option fails `nix flake check`
      checks = forAllSystems (pkgs: {
        module =
          (nixpkgs.lib.nixosSystem {
            inherit (pkgs.stdenv.hostPlatform) system;
            modules = [
              self.nixosModules.default
              {
                services.folio.enable = true;
                nixpkgs.config.allowUnfreePredicate = p: nixpkgs.lib.getName p == "claude-code";
                boot.isContainer = true;
                system.stateVersion = "26.05";
              }
            ];
          }).config.system.build.toplevel;
      });
    };
}
