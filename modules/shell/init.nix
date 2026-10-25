{
  flake.modules.homeManager.default =
    { config, lib, ... }:
    let
      shellInit = ''SHELLRC_SKIP_PROMPT=1 source "${config.xdg.configHome}/shellrc.d/index.sh"'';
    in
    {
      xdg.configFile."shellrc.d".source = ../../shell;
      programs.bash.initExtra = lib.mkAfter shellInit;
      programs.zsh.initContent = lib.mkAfter shellInit;
    };
}
