{
  flake.modules.homeManager.default =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      home.file.".config/amp/plugins/readiff.ts" = {
        source = ../packages/readiff/plugins/amp/readiff.ts;
        force = true;
      };
      home.file.".config/amp/plugins/desloppify.ts" = {
        source = ../packages/readiff/plugins/amp/desloppify.ts;
        force = true;
      };

      # Merge only these keys: Amp must retain a writable, machine-local settings file.
      home.activation.ampKeymap = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${pkgs.python3}/bin/python3 ${../scripts/configure-amp-keymap.py} \
          ${lib.escapeShellArg "${config.home.homeDirectory}/.config/amp/settings.json"} \
          ${lib.escapeShellArg (
            builtins.toJSON {
              "thread.interrupt" = [
                "ctrl+l"
                "esc esc"
              ];
            }
          )}
      '';
    };
}
