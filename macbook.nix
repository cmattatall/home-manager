{
  config,
  lib,
  pkgs,
  nixpkgs-unstable,
  ...
}:
let
  unstable = import nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfreePredicate = pkg: lib.getName pkg == "amp-cli";
  };
in
{
  imports = [ ./home.nix ];

  home.stateVersion = "26.05";
  home.sessionPath = [ "${config.home.profileDirectory}/bin" ];
  # OMP is absent and Amp is older in the stable release.
  # Unstable no longer supports Intel Macs.
  nixpkgs.overlays = [
    (_: prev: lib.optionalAttrs prev.stdenv.hostPlatform.isAarch64 { amp-cli = unstable.amp-cli; })
  ];
  home.packages = lib.optionals pkgs.stdenv.hostPlatform.isAarch64 [ unstable.omp ];
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
  };
  programs.zsh.enable = true;
  programs.zsh.envExtra = ''
    if [[ -r "$HOME/.zshenv.local" ]]; then
      source "$HOME/.zshenv.local"
    fi
  '';
  programs.zsh.profileExtra = ''
    if [[ -r "$HOME/.zprofile.local" ]]; then
      source "$HOME/.zprofile.local"
    fi
  '';
  programs.zsh.initContent = lib.mkMerge [
    (lib.mkBefore ''
      if [[ -r "$HOME/.zshrc.local" ]]; then
        source "$HOME/.zshrc.local"
      fi
    '')
    (lib.mkAfter ''
      # Remote cleanup cannot reach Kitty after a broken SSH connection.
      _hm_clear_kitty_tmux() {
        if [[ -n "''${KITTY_WINDOW_ID:-}" && -z "''${TMUX:-}" ]]; then
          printf '\033]1337;SetUserVar=in_tmux\007'
        fi
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook precmd _hm_clear_kitty_tmux
    '')
  ];

  programs.kitty = {
    enable = true;
    settings = {
      term = "xterm-256color";
      enabled_layouts = "splits";
      # Left Option sends Alt shortcuts; Right Option keeps special characters.
      macos_option_as_alt = "left";
    };
    extraConfig = ''
      map cmd+enter no_op
      # Preserve Command through tmux with an explicit CSI-u press event.
      map cmd+w send_text all \x1b[119;9:1u
      map ctrl+shift+enter launch --cwd=current
      map ctrl+shift+alt+enter launch --cwd=current --location=hsplit
      map ctrl+shift+left neighboring_window left
      map ctrl+shift+right neighboring_window right
      map ctrl+shift+up neighboring_window up
      map ctrl+shift+down neighboring_window down
      map cmd+backspace send_text all \x15
      map alt+backspace send_text all \x1b\x7f
      # Preserve bracket modifiers for Review's unseen-hunk navigation.
      map ctrl+shift+[ send_text all \x1b[91;6u
      map ctrl+shift+] send_text all \x1b[93;6u

      # Open links locally even when an app inside tmux captures the mouse.
      mouse_map cmd+left release grabbed,ungrabbed mouse_handle_click link
      mouse_map cmd+left press grabbed,ungrabbed discard_event

      map --when-focus-on var:in_tmux ctrl+shift+enter send_text all \x1b[13;6u
      map --when-focus-on var:in_tmux ctrl+shift+alt+enter send_text all \x1b[13;8u
      map --when-focus-on var:in_tmux ctrl+shift+up send_text all \x1b[1;6A
      map --when-focus-on var:in_tmux ctrl+shift+down send_text all \x1b[1;6B
      map --when-focus-on var:in_tmux ctrl+shift+right send_text all \x1b[1;6C
      map --when-focus-on var:in_tmux ctrl+shift+left send_text all \x1b[1;6D
    '';
  };
}
