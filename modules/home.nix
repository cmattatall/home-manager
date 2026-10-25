{ inputs, ... }:
{
  flake.modules.homeManager.default = { lib, pkgs, ... }: {
    # Compatibility baseline, not the installed Nixpkgs version.
    home.stateVersion = lib.mkDefault "25.05";

    nixpkgs.config.allowUnfreePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "amp-cli"
        "vagrant"
      ];

    # macOS uses Apple's SSH for UseKeychain and system Keychain integration.
    home.packages = [
      pkgs.amp-cli
      pkgs.bashInteractive
      pkgs.zsh
      pkgs.fzf
      pkgs.bat
      pkgs.btop
      pkgs.presenterm
      pkgs.git
      pkgs.gh
      pkgs.gitleaks
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.findutils
      pkgs.which
      pkgs.curl
      pkgs.python3
      pkgs.nodejs
      pkgs.jq
      pkgs.awscli2
      pkgs.postgresql
      pkgs.cmake
      pkgs.gnumake
      pkgs.ninja
      pkgs.clang
      pkgs.llvm
      pkgs.llvm.dev
      pkgs.pre-commit
      pkgs.cargo
      pkgs.rustc
      (
        if pkgs.stdenv.hostPlatform.system == "x86_64-darwin" then
          pkgs.pkgsCross.arm-embedded.buildPackages.gcc
        else
          pkgs.gcc-arm-embedded
      )
    ]
    # Use official binaries: the Nixpkgs source build fails to link on Linux.
    ++ lib.optionals (pkgs.stdenv.hostPlatform.system != "x86_64-darwin") [
      inputs.herdr-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
    ]
    ++ lib.optionals (!pkgs.stdenv.hostPlatform.isDarwin) [ pkgs.openssh ];

    programs.home-manager.enable = true;
  };
}
