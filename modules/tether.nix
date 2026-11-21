{
  flake.modules.homeManager.default = { pkgs, ... }: {
    home.packages = [
      (pkgs.callPackage ../packages/tether/package.nix { nixpkgsSource = pkgs.path; })
    ];
  };

  perSystem = { pkgs, config, ... }: {
    packages.tether = pkgs.callPackage ../packages/tether/package.nix { nixpkgsSource = pkgs.path; };
    checks.tether = config.packages.tether;
    devShells.tether = pkgs.mkShell {
      packages = [
        pkgs.cargo
        pkgs.rustc
        pkgs.rustfmt
        pkgs.clippy
        pkgs.nodejs
        pkgs.git
        pkgs.go
        pkgs.gopls
        pkgs.nixfmt
        pkgs.statix
        pkgs.deadnix
        pkgs.shellcheck
        pkgs.shfmt
        pkgs.pre-commit
        pkgs.taplo
      ];
    };
  };
}
