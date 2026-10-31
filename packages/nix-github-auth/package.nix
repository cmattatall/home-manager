{
  writeShellApplication,
  python3,
  gh,
}:
writeShellApplication {
  name = "nix-github-auth";
  runtimeInputs = [
    python3
    gh
  ];
  text = ''
    exec python3 ${./auth.py} "$@"
  '';
}
