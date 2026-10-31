{
  perSystem = { pkgs, ... }: {
    packages.nix-github-auth = pkgs.callPackage ../packages/nix-github-auth/package.nix { };
    checks.nix-github-auth =
      pkgs.runCommand "nix-github-auth-tests"
        {
          nativeBuildInputs = [
            pkgs.python3
            pkgs.nix
          ];
        }
        ''
          python3 ${../packages/nix-github-auth}/test_auth.py
          touch $out
        '';
  };

  flake.modules.homeManager.default = { pkgs, ... }: {
    home.packages = [ (pkgs.callPackage ../packages/nix-github-auth/package.nix { }) ];
  };
}
