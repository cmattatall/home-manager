{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.personalPrompt;
  enabledByDefault = description: lib.mkEnableOption description // { default = true; };
in
{
  options.programs.personalPrompt = {
    enable = lib.mkEnableOption "the personal Starship prompt for Bash/Zsh";
    host = {
      enable = enabledByDefault "the hostname prefix";
      showOS = enabledByDefault "the operating system in the hostname prefix";
      showSSH = enabledByDefault "the SSH indicator in the hostname prefix";
    };
    directory.enable = enabledByDefault "the current directory segment";
    git.enable = enabledByDefault "the Git branch segment";
    nixShell.enable = enabledByDefault "the Nix-shell indicator";
    aws.enable = enabledByDefault "the AWS profile indicator";
    exitStatus.enable = enabledByDefault "the nonzero exit-status prefix";
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.optional cfg.git.enable pkgs.git;
    programs.starship = {
      enable = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
      settings = lib.mapAttrsRecursive (_: lib.mkDefault) (
        lib.recursiveUpdate (builtins.fromTOML (builtins.readFile ../shell/starship.toml)) {
          hostname.disabled = !cfg.host.enable;
          hostname.ssh_symbol = if cfg.host.showSSH then "ssh:" else "";
          os.disabled = !(cfg.host.enable && cfg.host.showOS);
          directory.disabled = !cfg.directory.enable;
          git_branch.disabled = !cfg.git.enable;
          nix_shell.disabled = !cfg.nixShell.enable;
          aws.disabled = !cfg.aws.enable;
          status.disabled = !cfg.exitStatus.enable;
        }
      );
    };
  };
}
