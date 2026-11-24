{
  lib,
  stdenv,
  rustPlatform,
  buildNpmPackage,
  makeWrapper,
  git,
  go,
  gopls,
  xdg-utils,
  zenity,
  openssh,
  nix,
  nixpkgsSource,
  remoteExpression ? null,
}:
let
  source = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: _type:
      !(builtins.elem (baseNameOf path) [
        "target"
        "node_modules"
        "dist"
      ]);
  };
  bootstrapExpression =
    if remoteExpression != null then
      remoteExpression
    else
      builtins.toFile "tether-remote.nix" ''
        let pkgs = import ${nixpkgsSource} { };
        in pkgs.callPackage ${source}/package.nix {
          nixpkgsSource = pkgs.path;
          remoteExpression = builtins.storePath __curPos.file;
        }
      '';
  frontend = buildNpmPackage {
    pname = "tether-ui";
    version = "0.1.0";
    src = lib.cleanSourceWith {
      src = ./frontend;
      filter =
        path: _type:
        !(builtins.elem (baseNameOf path) [
          "node_modules"
          "dist"
        ]);
    };
    npmDepsHash = "sha256-yeYdym5Ovp2LBKZLg+yzXbmMwDENk4ctRqie0yBm0K4=";
    preBuild = ''
      npm run lint
    '';
    installPhase = ''
      mkdir -p $out
      cp -r dist/. $out/
    '';
  };
in
rustPlatform.buildRustPackage {
  pname = "tether";
  version = "0.1.0";
  src = source;
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    git
    go
    gopls
  ];
  preCheck = ''
    export HOME="$TMPDIR/tether-home"
    mkdir -p "$HOME"
  '';
  preBuild = ''
    mkdir -p frontend/dist
    cp -r ${frontend}/. frontend/dist/
  '';
  postInstall = ''
    $out/bin/tether-schema | diff frontend/src/protocol.ts -
    wrapProgram $out/bin/tether --set TETHER_REMOTE_EXPRESSION ${bootstrapExpression} --prefix PATH : ${
      lib.makeBinPath (
        [
          git
          gopls
          nix
        ]
        ++ lib.optionals stdenv.hostPlatform.isLinux [
          xdg-utils
          zenity
          openssh
        ]
      )
    }
  '';
  meta = {
    description = "Source-bound feedback for agent development";
    mainProgram = "tether";
    platforms = lib.platforms.unix;
  };
}
