# Nix configuration

- Use the [dendritic Nix pattern](https://github.com/mightyiam/dendritic).
  Organize configuration by feature in `modules/`, with each Nix file defining
  a flake-parts module loaded automatically by `import-tree`.
- Keep a feature's Home Manager settings, package outputs, checks, and development
  shells together in its owning module. Extend that module when changing the feature.
- Contribute Home Manager settings through `flake.modules.homeManager.<name>`.
  Put shared behavior in the feature's `default` contribution and platform-specific
  settings in the appropriate profile under `modules/profiles/`.
- Keep `flake.nix` focused on inputs and module loading. Put program source and
  package recipes under `packages/`. See the root README's development section
  for package integration and verification commands.
