#!/usr/bin/env bash
set -euo pipefail

# Git hooks export repository paths that would redirect fixture Git commands.
while IFS= read -r variable; do
	unset "$variable"
done < <(git rev-parse --local-env-vars)

cargo fmt --manifest-path packages/tether/Cargo.toml --all --check
taplo fmt --check packages/tether/Cargo.toml packages/tether/terminal/Cargo.toml
taplo check packages/tether/Cargo.toml packages/tether/terminal/Cargo.toml
nixfmt --check modules/tether.nix packages/tether/package.nix
statix check modules/tether.nix
statix check packages/tether/package.nix
deadnix --fail modules/tether.nix packages/tether/package.nix
shellcheck packages/tether/check.sh
shfmt -d packages/tether/check.sh

npm --prefix packages/tether/frontend ci --ignore-scripts
npm --prefix packages/tether/frontend run format:check
npm --prefix packages/tether/frontend run lint
npm --prefix packages/tether/frontend run build
npm --prefix packages/tether/terminal/browser ci --ignore-scripts
npm --prefix packages/tether/terminal/browser run format:check
npm --prefix packages/tether/terminal/browser run check
cargo clippy --locked --manifest-path packages/tether/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path packages/tether/Cargo.toml
cargo run --quiet --locked --manifest-path packages/tether/Cargo.toml --bin tether-schema |
	diff packages/tether/frontend/src/protocol.ts -
cargo run --quiet --locked --manifest-path packages/tether/Cargo.toml -p tether-terminal --example browser_schema |
	diff packages/tether/terminal/browser/src/protocol.ts -
