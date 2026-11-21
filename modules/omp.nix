{ inputs, ... }:
{
  flake.modules.homeManager.default =
    { lib, pkgs, ... }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      unstable = import inputs.nixpkgs-unstable { inherit system; };
    in
    {
      home.packages = lib.optionals (system != "x86_64-darwin") [ unstable.omp ];
    };
}
