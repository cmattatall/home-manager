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
}:
let
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
    npmDepsHash = "sha256-lYMO8es4d1SsrC+Lwt2NaufsMtFr6sq9JmT67lCybD8=";
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
  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: _type:
      !(builtins.elem (baseNameOf path) [
        "target"
        "node_modules"
        "dist"
      ]);
  };
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
    wrapProgram $out/bin/tether --prefix PATH : ${
      lib.makeBinPath (
        [
          git
          gopls
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
