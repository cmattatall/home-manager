{
  flake.modules.homeManager.default = {
    programs.tmux = {
      enable = true;
      mouse = true;
      extraConfig = ''
        bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel
        bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel

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
  };
}
