{ config, ... }:
{
  flake.modules.homeManager.default.imports = [ config.flake.modules.homeManager.zellij ];

  flake.modules.homeManager.zellij =
    { config, pkgs, ... }:
    let
      # Replace these with user@hostname targets, or aliases from ~/.ssh/config.
      targets = {
        web = "user@web.example.com";
        lab = "user@lab.example.com";
        staging = "user@staging.example.com";
      };
      # Keep Apple's UseKeychain support on macOS.
      ssh = if pkgs.stdenv.hostPlatform.isDarwin then "/usr/bin/ssh" else "${pkgs.openssh}/bin/ssh";
      zellij = "${config.programs.zellij.package}/bin/zellij";
      sidebar = pkgs.writeShellScript "machine-sidebar" ''
        printf '%s\n' \
          'Machine Sidebar' "" \
          '1  Web-Server' '2  Home-Lab' '3  Staging' "" \
          'Alt+g: unlock/lock hub' \
          'Unlocked: Ctrl+t for tabs' \
          'Unlocked: Ctrl+p for panes' \
          'Remote Zellij: Ctrl+g' ""
        while read -r -p 'Select machine [1-3]: ' choice; do
          case "$choice" in
            1) tab=Web-Server ;;
            2) tab=Home-Lab ;;
            3) tab=Staging ;;
            *) continue ;;
          esac
          ${zellij} action go-to-tab-name "$tab"
        done
      '';
    in
    {
      programs.zellij = {
        enable = true;
        # Launch explicitly with cluster-dash, never on every shell/SSH login.
        enableBashIntegration = false;
        enableZshIntegration = false;
        enableFishIntegration = false;
        settings = {
          simplified_ui = true;
          theme = "nord";
          default_mode = "locked";
        };
      };

      xdg.configFile."zellij/layouts/machines.kdl".text = ''
        // Keep the hub visible and use the explicit lock key instead of the
        // Zellij 0.45+ nested-session prompt/automatic focus routing.
        nested_session_handling "never"

        // Only the hub uses Alt+g. Remote sessions keep the standard Ctrl+g,
        // even if this Home Manager module is installed on those hosts too.
        keybinds {
            unbind "Ctrl g"
            locked {
                bind "Alt g" { SwitchToMode "Normal"; }
            }
            shared_except "locked" {
                bind "Alt g" { SwitchToMode "Locked"; }
            }
        }

        layout {
            default_tab_template {
                pane size=1 borderless=true {
                    plugin location="zellij:tab-bar"
                }
                children
                pane size=2 borderless=true {
                    plugin location="zellij:status-bar"
                }
            }

            tab name="Dashboard" focus=true {
                pane split_direction="vertical" {
                    pane name="Machine Sidebar" size="25%" command="${sidebar}"
                    pane name="Local Shell" focus=true
                }
            }
            tab name="Web-Server" {
                pane command="${ssh}" close_on_exit=false {
                    args "-t" ${builtins.toJSON targets.web} "zellij attach --create work"
                }
            }
            tab name="Home-Lab" {
                pane command="${ssh}" close_on_exit=false {
                    args "-t" ${builtins.toJSON targets.lab} "zellij attach --create work"
                }
            }
            tab name="Staging" {
                pane command="${ssh}" close_on_exit=false {
                    args "-t" ${builtins.toJSON targets.staging} "zellij attach --create work"
                }
            }
        }
      '';

      home.packages = [
        (pkgs.writeShellScriptBin "cluster-dash" ''
          exec ${zellij} --layout machines "$@"
        '')
      ];
    };
}
