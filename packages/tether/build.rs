use sha2::{Digest, Sha256};
use std::{fs, path::Path};

fn hash_source(path: &Path, digest: &mut Sha256) {
    if path.is_dir() {
        let mut children: Vec<_> = fs::read_dir(path)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| {
                !matches!(
                    path.file_name().unwrap().to_str(),
                    Some("node_modules" | "dist")
                )
            })
            .collect();
        children.sort();
        for child in children {
            hash_source(&child, digest);
        }
    } else {
        let bytes = fs::read(path).unwrap();
        digest.update(path.to_str().unwrap().as_bytes());
        digest.update([0]);
        digest.update((bytes.len() as u64).to_be_bytes());
        digest.update(bytes);
    }
}

fn main() {
    println!("cargo:rerun-if-changed=frontend/dist");
    let mut digest = Sha256::new();
    for path in [
        "src",
        "terminal/src",
        "terminal/Cargo.toml",
        "frontend",
        "Cargo.toml",
        "Cargo.lock",
        "build.rs",
        "package.nix",
    ] {
        println!("cargo:rerun-if-changed={path}");
        hash_source(Path::new(path), &mut digest);
    }
    println!("cargo:rustc-env=TETHER_BUILD_ID={:x}", digest.finalize());
}
