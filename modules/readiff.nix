{
  inputs,
  config,
  lib,
  ...
}:
{
  perSystem = { inputs', ... }: {
    packages = {
      inherit (inputs'.readiff.packages) default rediff;
    };
    apps = {
      inherit (inputs'.readiff.apps) default;
      rediff = inputs'.readiff.apps.default;
    };

    # Run against the same pins as the personal profiles.
    checks = {
      rediff-review = inputs'.readiff.checks.review;
      rediff-amp = inputs'.readiff.checks.rediff-amp;
      rediff-home-manager = inputs'.readiff.checks.home-manager-composition;
      rediff-harnesses = inputs'.readiff.checks.harnesses;
    };
  };

  flake.modules.homeManager = {
    rediff = { pkgs, ... }: {
      imports = [ inputs.readiff.homeManagerModules.default ];

      # Use the consumer's package set, including stable Intel macOS support.
      programs.rediff.package = lib.mkDefault (
        pkgs.callPackage ../packages/readiff/nix/package.nix { inputs = inputs.readiff.inputs; }
      );
    };

    default = {
      imports = [ config.flake.modules.homeManager.rediff ];
      programs.rediff = {
        enable = lib.mkDefault true;
        nvimAlias = lib.mkDefault true;
        vimAlias = lib.mkDefault true;
        manageSettings = lib.mkDefault false;
        ampPlugin.enable = lib.mkDefault false;
        ompPlugin.enable = lib.mkDefault false;
      };
    };
  };
}
