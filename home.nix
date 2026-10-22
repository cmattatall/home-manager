{
  config,
  lib,
  pkgs,
  nixpkgs-unstable,
  ...
}:
let
  shellInit = ''SHELLRC_SKIP_PROMPT=1 source "${config.xdg.configHome}/shellrc.d/index.sh"'';
in
{
  imports = [
    ./modules/prompt.nix
    ./modules/editor/rediff.nix
    ./modules/zellij.nix
  ];
  programs.personalPrompt.enable = lib.mkDefault true;
  programs.rediff = {
    enable = lib.mkDefault true;
    nvimAlias = lib.mkDefault true;
    vimAlias = lib.mkDefault true;
    # Preserve settings and plugins already managed outside Home Manager.
    manageSettings = lib.mkDefault false;
    ampPlugin.enable = lib.mkDefault false;
    ompPlugin.enable = lib.mkDefault false;
  };

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
  # Herdr is absent from stable; unstable no longer supports Intel Macs.
  ++ lib.optionals (pkgs.stdenv.hostPlatform.system != "x86_64-darwin") [
    nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.herdr
  ]
  ++ lib.optionals (!pkgs.stdenv.hostPlatform.isDarwin) [ pkgs.openssh ];
  xdg.configFile."shellrc.d".source = ./shell;
  programs.bash.initExtra = lib.mkAfter shellInit;
  programs.zsh.initContent = lib.mkAfter shellInit;

  # Merge only these keys: Amp must retain a writable, machine-local settings file.
  home.activation.ampKeymap = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.python3}/bin/python3 ${./scripts/configure-amp-keymap.py} \
      ${lib.escapeShellArg "${config.home.homeDirectory}/.config/amp/settings.json"} \
      ${lib.escapeShellArg (builtins.toJSON {
        "thread.interrupt" = [ "ctrl+l" "esc esc" ];
      })}
  '';

  programs.home-manager.enable = true;
  programs.tmux = {
    enable = true;
    mouse = true;
    extraConfig = ''
      # Copy on mouse release without clearing the visible selection.
      bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-no-clear
      bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-no-clear

      bind-key -n C-S-Enter split-window -h -c '#{pane_current_path}'
      bind-key -n C-M-S-Enter split-window -v -c '#{pane_current_path}'
      bind-key -n C-S-Left select-pane -L
      bind-key -n C-S-Right select-pane -R
      bind-key -n C-S-Up select-pane -U
      bind-key -n C-S-Down select-pane -D
      # Forward CSI-u explicitly instead of collapsing Ctrl+[ to Escape.
      bind-key -n C-S-[ send-keys -l "\033[91;6u"
      bind-key -n C-S-] send-keys -l "\033[93;6u"

      # Preserve OSC 8 links for the outer terminal to open (including over SSH).
      set -as terminal-features ',*:hyperlinks'
      # Kitty uses xterm-256color here; retain RGB instead of quantizing diff colors.
      set -as terminal-features ',xterm-256color:RGB'

      # Terminal entry/exit also covers suspend/resume, unlike client hooks.
      set -as terminal-overrides ',xterm*:smcup=\E[?1049h\E[22;0;0t\E]1337;SetUserVar=in_tmux=MQ==\007:rmcup=\E[?1049l\E[23;0;0t\E]1337;SetUserVar=in_tmux\007'
    '';
  };
}
