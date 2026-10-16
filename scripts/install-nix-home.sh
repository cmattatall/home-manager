#!/usr/bin/env bash
# Write the pinned development-node configuration without overwriting an existing file.
set -euC

: "${HOME:?HOME must be set}"
cat > "$HOME/home.nix" <<'EOF'
let
  personal = builtins.getFlake (
    "git+https://github.com/cmattatall/home-manager.git"
    + "?rev=85a2e6a2be519709571599795d1f945ab5e036f4"
  );
  pull = ''
    home-manager-pull() {
      local config_file="$HOME/home.nix"
      local repository_url="https://github.com/cmattatall/home-manager.git"
      local remote_reference latest_revision
      local revision_pin_pattern matching_pin_count updated_config

      # Look up main without cloning the repository or changing local files.
      if ! remote_reference=$(git ls-remote --exit-code "$repository_url" refs/heads/main); then
        printf 'home-manager-pull: could not read main from %s\n' "$repository_url" >&2
        return 1
      fi

      # ls-remote returns a commit SHA followed by a tab and the branch name.
      latest_revision=$(printf '%s\n' "$remote_reference" | cut -f1)
      if ! [[ "$latest_revision" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'home-manager-pull: main did not resolve to a valid commit SHA\n' >&2
        return 1
      fi

      # Refuse ambiguous or edited configurations instead of replacing other SHAs.
      revision_pin_pattern='^[[:space:]]*\+ "\?rev=[0-9a-f]{40}"$'
      matching_pin_count=$(grep -Ec "$revision_pin_pattern" "$config_file")
      if [ "$matching_pin_count" != 1 ]; then
        printf 'home-manager-pull: expected exactly one revision pin in %s\n' "$config_file" >&2
        return 1
      fi

      # Prepare the update beside home.nix so a failed write leaves it intact.
      if ! updated_config=$(mktemp "$config_file.XXXXXX"); then
        printf 'home-manager-pull: could not create a temporary configuration\n' >&2
        return 1
      fi

      # Only replace the SHA on the revision-pin line; preserve everything else.
      if ! sed -E "/$revision_pin_pattern/s/[0-9a-f]{40}/$latest_revision/" \
        "$config_file" > "$updated_config"; then
        rm -f "$updated_config"
        return 1
      fi

      if ! mv "$updated_config" "$config_file"; then
        rm -f "$updated_config"
        return 1
      fi

      # Explicitly use this configuration and keep Home Manager's backup behavior.
      # If activation fails, leave the new pin in place so the switch can be retried.
      home-manager switch -b backup -f "$config_file"
    }
  '';
in
{
  imports = [ personal.homeModules.development-node ];
  home.username = "developer";
  home.homeDirectory = "/home/developer";
  programs.home-manager.path = personal.inputs.home-manager.outPath;
  programs.bash.initExtra = pull;
  programs.zsh.initContent = pull;
}
EOF

printf 'Created %s/home.nix\n' "$HOME"

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/home-manager"
mkdir -p "$config_dir"
if [ ! -e "$config_dir/home.nix" ] && [ ! -L "$config_dir/home.nix" ]; then
  ln -s "$HOME/home.nix" "$config_dir/home.nix"
else
  printf 'Preserved existing %s/home.nix; use -f "$HOME/home.nix" explicitly.\n' "$config_dir"
fi

cat <<'EOF'
For the first activation without a Home Manager channel, run:
  hm_source=$(nix --extra-experimental-features 'nix-command flakes' eval --impure --raw --expr '(import (builtins.getEnv "HOME" + "/home.nix")).programs.home-manager.path')
  home-manager switch -b backup -f "$HOME/home.nix" -I "home-manager=$hm_source"
After activation, the installed Home Manager CLI uses that pinned source.
EOF
