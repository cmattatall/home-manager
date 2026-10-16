{
  lib,
  pkgs,
  readiff,
  ...
}:
{
  imports = [ (import ./rediff/nix/home-manager.nix { self = readiff; }) ];

  # Use the consumer's package set, including stable Intel macOS support.
  programs.rediff.package = lib.mkDefault (
    pkgs.callPackage "${readiff}/nix/package.nix" { inputs = readiff.inputs; }
  );
}
