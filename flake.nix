{
  description = "Carl's portable Home Manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    readiff = {
      url = "path:./modules/editor/rediff";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      readiff,
      ...
    }:
    let
      shared = {
        imports = [ ./home.nix ];
        _module.args = { inherit readiff nixpkgs-unstable; };
      };
      mkHome =
        system: username: module:
        home-manager.lib.homeManagerConfiguration {
          pkgs = import nixpkgs { inherit system; };
          modules = [
            shared
            module
            {
              home = {
                inherit username;
                homeDirectory =
                  if nixpkgs.lib.hasSuffix "-darwin" system then "/Users/${username}" else "/home/${username}";
              };
            }
          ];
        };
    in
    {
      inherit (readiff) packages apps;
      # Exercise the editor against the same stable inputs used by our profiles.
      # The standalone rediff flake also tests its optional OMP/bootstrap setup.
      checks = nixpkgs.lib.mapAttrs (_: checks: {
        rediff-review = checks.review;
        rediff-amp = checks.rediff-amp;
        rediff-home-manager = checks.home-manager-composition;
        rediff-harnesses = checks.harnesses;
      }) readiff.checks;

      homeModules = {
        default = shared;
        prompt = ./modules/prompt.nix;
        rediff = {
          imports = [ ./modules/editor/rediff.nix ];
          _module.args = { inherit readiff; };
        };
        development-node.imports = [
          shared
          ./development-node.nix
        ];
        macbook.imports = [
          shared
          ./macbook.nix
        ];
      };

      homeConfigurations = {
        development-node = mkHome "x86_64-linux" "cmattatall" ./development-node.nix;
        macbook = mkHome "aarch64-darwin" "cmattatall" ./macbook.nix;
        macbook-intel = mkHome "x86_64-darwin" "cmattatall" ./macbook.nix;
      };

      nixosModules.default = {
        home-manager.users.cmattatall.imports = [ shared ];
      };
    };
}
