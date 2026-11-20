use anyhow::{Context, Result, ensure};
use std::{
    collections::BTreeSet,
    path::{Component, Path, PathBuf},
    process::Command,
};

use crate::model::{ChangedFile, MAX_SOURCE, Scope};

pub fn git(directory: &Path, arguments: &[&str]) -> Result<Vec<u8>> {
    let output = Command::new("git")
        .args([
            "--no-optional-locks",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
        ])
        .args(arguments)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_LAZY_FETCH", "1")
        .current_dir(directory)
        .output()?;
    ensure!(
        output.status.success(),
        "Git query failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(output.stdout)
}

pub fn root(directory: &Path) -> Result<PathBuf> {
    let output = git(directory, &["rev-parse", "--show-toplevel"])?;
    let path = String::from_utf8(output)?;
    Ok(Path::new(path.trim_end_matches('\n')).canonicalize()?)
}

pub fn files(directory: &Path) -> Result<Vec<String>> {
    let output = git(
        directory,
        &[
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ],
    )?;
    let mut paths = BTreeSet::new();
    for bytes in output
        .split(|byte| *byte == 0)
        .filter(|bytes| !bytes.is_empty())
    {
        let path = std::str::from_utf8(bytes).context("Source path must be UTF-8")?;
        paths.insert(path.to_owned());
    }
    ensure!(
        paths.len() <= 20_000,
        "This initial source browser supports up to 20,000 paths"
    );
    Ok(paths.into_iter().collect())
}

pub fn source(directory: &Path, relative: &str) -> Result<String> {
    let path = Path::new(relative);
    ensure!(
        !relative.is_empty()
            && path
                .components()
                .all(|part| matches!(part, Component::Normal(_))),
        "Source path must be relative to the worktree"
    );
    ensure!(
        !path.components().any(|part| part.as_os_str() == ".git"),
        "Git metadata is outside the source browser"
    );
    use rustix::fs::{Mode, OFlags, openat};
    let mut file = std::fs::File::open(directory)?;
    for component in path.components() {
        let descriptor = openat(
            &file,
            component.as_os_str(),
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC | OFlags::NONBLOCK,
            Mode::empty(),
        )
        .context(
            "Source paths must use regular directories and files. Symbolic links are unsupported",
        )?;
        file = descriptor.into();
    }
    ensure!(file.metadata()?.is_file(), "Source must be a regular file");
    use std::io::Read;
    let mut bytes = Vec::new();
    file.take(MAX_SOURCE + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_SOURCE,
        "Source exceeds the initial 64 KiB capture limit"
    );
    ensure!(!bytes.contains(&0), "Binary source is unavailable");
    String::from_utf8(bytes).context("Source must be UTF-8")
}

pub fn head(directory: &Path) -> Result<Option<String>> {
    let output = Command::new("git")
        .args(["rev-parse", "--verify", "--quiet", "HEAD"])
        .current_dir(directory)
        .output()?;
    if output.status.code() == Some(1) {
        return Ok(None);
    }
    ensure!(output.status.success(), "Cannot resolve worktree HEAD");
    Ok(Some(String::from_utf8(output.stdout)?.trim().to_owned()))
}

pub fn changes(directory: &Path, scope: &Scope) -> Result<Vec<ChangedFile>> {
    let head = head(directory)?;
    let mut entries = std::collections::BTreeMap::new();
    if head.is_none() && *scope == Scope::Uncommitted {
        for path in files(directory)? {
            match std::fs::symlink_metadata(directory.join(&path)) {
                Ok(_) => {
                    entries.insert(path, "A".to_owned());
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
    } else {
        let mut arguments = vec![
            "diff",
            "--name-status",
            "-z",
            "--no-renames",
            "--no-ext-diff",
            "--no-textconv",
        ];
        match scope {
            Scope::Uncommitted => arguments.push("HEAD"),
            Scope::Staged => arguments.push("--cached"),
            Scope::Unstaged => {}
        }
        arguments.push("--");
        let output = git(directory, &arguments)?;
        let fields: Vec<_> = output
            .split(|byte| *byte == 0)
            .filter(|field| !field.is_empty())
            .collect();
        ensure!(fields.len() % 2 == 0, "Invalid Git change list");
        for pair in fields.chunks_exact(2) {
            entries.insert(
                std::str::from_utf8(pair[1])?.to_owned(),
                std::str::from_utf8(pair[0])?.to_owned(),
            );
        }
    }
    if *scope != Scope::Staged {
        let output = git(
            directory,
            &["ls-files", "--others", "--exclude-standard", "-z"],
        )?;
        for path in output
            .split(|byte| *byte == 0)
            .filter(|path| !path.is_empty())
        {
            entries.insert(std::str::from_utf8(path)?.to_owned(), "A".into());
        }
    }
    Ok(entries
        .into_iter()
        .map(|(path, status)| ChangedFile { path, status })
        .collect())
}

pub fn git_source(directory: &Path, revision: Option<&str>, path: &str) -> Result<Option<String>> {
    let output = match revision {
        Some(revision) => git(
            directory,
            &[
                "ls-tree",
                "-z",
                revision,
                "--",
                &format!(":(literal){path}"),
            ],
        )?,
        None => git(
            directory,
            &[
                "ls-files",
                "--stage",
                "-z",
                "--",
                &format!(":(literal){path}"),
            ],
        )?,
    };
    if output.is_empty() {
        return Ok(None);
    }
    let entries: Vec<_> = output
        .split(|byte| *byte == 0)
        .filter(|entry| !entry.is_empty())
        .collect();
    ensure!(
        entries.len() == 1,
        "Unmerged index stages require conflict review"
    );
    let entry = std::str::from_utf8(entries[0])?;
    let (metadata, actual_path) = entry.split_once('\t').context("Invalid Git source entry")?;
    ensure!(actual_path == path, "Git source path mismatch");
    let fields: Vec<_> = metadata.split_whitespace().collect();
    ensure!(
        matches!(fields[0], "100644" | "100755"),
        "This entry is metadata-only: symlink or submodule"
    );
    let object = if revision.is_some() {
        fields[2]
    } else {
        ensure!(
            fields[2] == "0",
            "Unmerged index stage requires conflict review"
        );
        fields[1]
    };
    let size: u64 = String::from_utf8(git(directory, &["cat-file", "-s", object])?)?
        .trim()
        .parse()?;
    ensure!(
        size <= MAX_SOURCE,
        "Source exceeds the initial 64 KiB capture limit"
    );
    let bytes = git(directory, &["cat-file", "blob", object])?;
    ensure!(!bytes.contains(&0), "Binary entry: text review unavailable");
    Ok(Some(
        String::from_utf8(bytes).context("Source must be UTF-8")?,
    ))
}

pub fn working_source(directory: &Path, path: &str) -> Result<Option<String>> {
    match std::fs::symlink_metadata(directory.join(path)) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
        Ok(_) => source(directory, path).map(Some),
    }
}
