{
  lib,
  stdenv,
  vimUtils,
  vimPlugins,
  neovim,
  neovim-unwrapped,
  wrapNeovim,
  fetchurl,
  makeWrapper,
  git,
  gh,
  ripgrep,
  fzf,
  difftastic,
  lua-language-server,
  nil,
  pyright,
  typescript-language-server,
  gopls,
  rust-analyzer,
  python3,
  bash,
  coreutils,
  inputs,
}:
let
  # Neovim 0.12.4 sends terminal OSC 52 newlines as NUL to command-based
  # clipboard providers (including tmux). This upstream fix ships in 0.12.5.
  terminalNeovim =
    if lib.versionOlder neovim-unwrapped.version "0.12.5" then
      wrapNeovim (neovim-unwrapped.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (fetchurl {
            url = "https://github.com/neovim/neovim/commit/e58f29ca3e6935af5b14879db1e8f2b959555c10.patch";
            hash = "sha256-tih56QXLCTEfMtQkWEKKK+bpZQIDTLb8+MMzd+I9no0=";
          })
        ];
      })) { }
    else
      neovim;
  codediff = vimUtils.buildVimPlugin {
    pname = "codediff.nvim";
    version = inputs.codediff.shortRev or "pinned";
    src = inputs.codediff;
    buildPhase = ''
      runHook preBuild
      bash build.sh
      runHook postBuild
    '';
    doCheck = false;
    doInstallCheck = false;
  };
  review = vimUtils.buildVimPlugin {
    pname = "review.nvim";
    version = inputs.review.shortRev or "pinned";
    src = inputs.review;
    doCheck = false;
    doInstallCheck = false;
  };
  treesitter = vimPlugins.nvim-treesitter.withPlugins (parsers: [
    parsers.go
    parsers.rust
    parsers.python
  ]);
  plugins = [
    codediff
    review
    vimPlugins.nui-nvim
    vimPlugins.neo-tree-nvim
    vimPlugins.fzf-lua
    vimPlugins.telescope-nvim
    vimPlugins.nvim-lspconfig
    vimPlugins.gitsigns-nvim
    vimPlugins.plenary-nvim
    vimPlugins.nvim-web-devicons
    vimPlugins.rose-pine
    treesitter
  ]
  ++ treesitter.dependencies; # Our manual runtimepath must include parsers and queries.
  runtime = lib.concatMapStringsSep "," toString plugins;
in
stdenv.mkDerivation {
  pname = "rediff";
  version = "0.1.0";
  src = ./config;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;
  installPhase = ''
    mkdir -p "$out/share/rediff" "$out/bin"
    cp -R . "$out/share/rediff/"
    install -Dm644 ${../LICENSE} "$out/share/licenses/rediff/LICENSE"
    ${terminalNeovim}/bin/nvim --headless -u NONE -i NONE -n \
      -c "helptags $out/share/rediff/doc" -c 'qa!'
    makeWrapper ${terminalNeovim}/bin/nvim "$out/bin/rediff" \
      --set NVIM_APPNAME rediff \
      --set REDIFF_RUNTIME "$out/share/rediff" \
      --set REDIFF_PLUGINS '${runtime}' \
      --set VSCODE_DIFF_NO_AUTO_INSTALL 1 \
      --prefix PATH : ${
        lib.makeBinPath [
          git
          gh
          ripgrep
          fzf
          difftastic
          lua-language-server
          nil
          pyright
          typescript-language-server
          gopls
          rust-analyzer
        ]
      } \
      --prefix PATH : "$out/bin" \
      --add-flags '-u' --add-flags "$out/share/rediff/init.lua"
    cp ${./harness.py} "$out/share/rediff/harness.py"
    makeWrapper ${python3}/bin/python3 "$out/bin/rediff-harness" \
      --add-flags "$out/share/rediff/harness.py"
    cp ${./amp_live.py} "$out/share/rediff/amp_live.py"
    makeWrapper ${python3}/bin/python3 "$out/bin/rediff-amp-live" \
      --add-flags "$out/share/rediff/amp_live.py"
    makeWrapper ${python3}/bin/python3 "$out/bin/rediff-omp-live" \
      --add-flags "$out/share/rediff/amp_live.py" --add-flags '--provider omp'
    makeWrapper ${python3}/bin/python3 "$out/bin/rediff-live" \
      --add-flags "$out/share/rediff/amp_live.py" --add-flags '--provider all'
    cp ${./clipboard.py} "$out/share/rediff/clipboard.py"
    for tool in xclip wl-copy pbcopy; do
      makeWrapper ${python3}/bin/python3 "$out/share/rediff/clipboard-bin/$tool" \
        --add-flags "$out/share/rediff/clipboard.py" --add-flags "$tool"
    done
    mkdir -p "$out/share/rediff/amp"
    cp ${../plugins/amp/readiff.ts} "$out/share/rediff/amp/readiff.ts"
    cp ${../plugins/amp/desloppify.ts} "$out/share/rediff/amp/desloppify.ts"
    cp ${../plugins/amp/install.sh} "$out/share/rediff/amp/install.sh"
    makeWrapper ${bash}/bin/bash "$out/bin/rediff-install-amp-plugin" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          python3
        ]
      } \
      --add-flags "$out/share/rediff/amp/install.sh"
    mkdir -p "$out/share/rediff/omp"
    cp ${../plugins/omp/rediff.ts} "$out/share/rediff/omp/rediff.ts"
    cp ${../plugins/omp/install.sh} "$out/share/rediff/omp/install.sh"
    makeWrapper ${bash}/bin/bash "$out/bin/rediff-install-omp-plugin" \
      --prefix PATH : ${lib.makeBinPath [ coreutils ]} \
      --add-flags "$out/share/rediff/omp/install.sh"
  '';
  meta = {
    description = "Read agent diffs with a portable modal review editor";
    license = lib.licenses.mit;
    mainProgram = "rediff";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
