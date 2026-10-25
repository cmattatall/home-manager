{
  inputs,
  config,
  lib,
  ...
}:
let
  homeModules = config.flake.modules.homeManager;
  mkHome =
    system: username: module:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = import inputs.nixpkgs { inherit system; };
      modules = [
        module
        {
          home = {
            inherit username;
            homeDirectory =
              if lib.hasSuffix "-darwin" system then "/Users/${username}" else "/home/${username}";
          };
        }
      ];
    };
in
{
  flake.homeConfigurations = {
    development-node = mkHome "x86_64-linux" "cmattatall" homeModules.development-node;
    macbook = mkHome "aarch64-darwin" "cmattatall" homeModules.macbook;
    macbook-intel = mkHome "x86_64-darwin" "cmattatall" homeModules.macbook;
  };

  flake.modules.nixos.default = {
    home-manager.users.cmattatall.imports = [ homeModules.default ];
  };
}
