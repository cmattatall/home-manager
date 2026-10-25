{ inputs, config, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];

  systems = [
    "aarch64-darwin"
    "aarch64-linux"
    "x86_64-linux"
  ];

  flake.homeModules = config.flake.modules.homeManager;
  flake.nixosModules = config.flake.modules.nixos;

  perSystem = { pkgs, ... }: {
    formatter = pkgs.nixfmt;
    devShells.default = pkgs.mkShellNoCC {
      packages = [
        pkgs.nixfmt
        pkgs.python3
        pkgs.bashInteractive
        pkgs.zsh
        pkgs.git
      ];
    };
  };
}
