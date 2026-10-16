{
  lib,
  pkgs,
  nixpkgs-unstable,
  ...
}:
{
  imports = [ ./home.nix ];

  # Keep Amp current without moving the rest of the profile off stable.
  nixpkgs.overlays = [
    (_: prev: {
      amp-cli =
        (import nixpkgs-unstable {
          system = prev.stdenv.hostPlatform.system;
          config.allowUnfreePredicate = pkg: lib.getName pkg == "amp-cli";
        }).amp-cli;
    })
  ];

  home.packages = [
    pkgs.screen
    pkgs.vagrant
    pkgs.usbutils
    pkgs.procps
  ];

  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  programs.zsh.enable = true;

  programs.bash = {
    enable = true;
    enableCompletion = true;
    shellAliases = {
      gs = "git status";
      ga = "git add";
      gp = "git push";
      gpo = "git push origin";
      gplo = "git pull origin";
      gb = "git branch ";
      gbc = "git branch --show-current";
      gc = "git commit";
      gd = "git diff";
      gco = "git checkout ";
      gl = "git log --pretty=oneline";
      gr = "git rebase -i";
      pc = "pre-commit run --all-files";
      nxd = "nix develop";
      cmklp = "cmake --list-presets";
      cmkp = "cmake --preset";
      cmkpb = "cmake --build -j$(nproc) --preset";
      killscreen = "screen -ls | grep Detached | cut -d. -f1 | awk '{print $1}' | xargs kill";
      vssh = "cd /var/lib/ubuntu-vm && sudo ${pkgs.vagrant}/bin/vagrant ssh";
      vreload = "cd /var/lib/ubuntu-vm && sudo ${pkgs.vagrant}/bin/vagrant reload";
    };
    initExtra = ''
      if [[ -n "''${SSH_CONNECTION:-}" ]] && shopt -q login_shell; then
        (
          other_ssh_sessions="$(
            LC_ALL=C who -uH | awk -v current_tty="''${SSH_TTY#/dev/}" \
              -v current_ip="''${SSH_CONNECTION%% *}" -v current_user="$(id -un)" '
              NR == 1 { next }
              $2 != current_tty && $NF ~ /^\(.*\)$/ {
                source_ip = substr($NF, 2, length($NF) - 2)
                if (source_ip == current_ip && $1 == current_user) next
                if (!found++)
                  printf "%-16s %-16s %-6s %s\n", "USER", "LOGIN", "IDLE", "FROM"
                printf "%-16s %-16s %-6s %s\n", $1, $3 " " $4, $5, $NF
              }
            '
          )"

          if [[ -n "$other_ssh_sessions" ]]; then
            banner_border='======================================================================'
            printf '\n\033[1;31m%s\n' "$banner_border"
            printf '  WARNING: SHARED LAB STATION HAS OTHER ACTIVE SSH SESSIONS\n'
            printf '%s\033[0m\n' "$banner_border"
            printf '\033[1mCoordinate before using shared hardware or changing system state.\033[0m\n\n'
            printf '%s\n' "$other_ssh_sessions"
            printf 'IDLE "." means active within the last minute; "old" means over 24 hours.\n'
            printf '\033[1;31m%s\033[0m\n\n' "$banner_border"
          fi
        )
      fi
    '';
  };

  programs.git = {
    enable = true;
    settings = {
      user.name = "cmattatall";
      user.email = "36604988+cmattatall@users.noreply.github.com";
      core.editor = "vim";
      push.autoSetupRemote = true;
      help.autoCorrect = "prompt";
    };
  };
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
  };
  programs.lazygit = {
    enable = true;
    settings.git.paging.pager = "delta --paging=never";
  };
}
