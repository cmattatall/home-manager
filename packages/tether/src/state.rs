use anyhow::{Context, Result, ensure};
use fs2::FileExt;
use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use crate::model::Worktree;

pub fn private_directory(path: &Path) -> Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)?;
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "State directory must be a real directory"
    );
    ensure!(
        metadata.permissions().mode() & 0o077 == 0,
        "State directory must have mode 0700: {}",
        path.display()
    );
    Ok(())
}

pub fn database(path: &Path) -> Result<Connection> {
    OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)?;
    let connection = Connection::open(path)?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    connection.execute_batch(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",
    )?;
    Ok(connection)
}

pub fn lock(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)?;
    file.try_lock_exclusive()
        .context("Another Tether process owns this state")?;
    Ok(file)
}

pub fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub fn secret() -> String {
    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock precedes Unix epoch")
        .as_secs() as i64
}

pub fn gateway_database(state: &Path) -> Result<Connection> {
    let connection = database(&state.join("gateway.sqlite"))?;
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS identity (id TEXT PRIMARY KEY);
         CREATE TABLE IF NOT EXISTS tickets (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL);
         CREATE TABLE IF NOT EXISTS sessions (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL);
         CREATE TABLE IF NOT EXISTS machines (id TEXT PRIMARY KEY, configuration TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS worktrees (id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, name TEXT NOT NULL);",
    )?;
    connection.execute(
        "INSERT INTO identity SELECT ?1 WHERE NOT EXISTS (SELECT 1 FROM identity)",
        [uuid::Uuid::new_v4().to_string()],
    )?;
    Ok(connection)
}

pub fn worktrees(state: &Path) -> Result<Vec<Worktree>> {
    let connection = gateway_database(state)?;
    let mut statement =
        connection.prepare("SELECT id, path, name FROM worktrees ORDER BY name, path")?;
    let entries = statement.query_map([], |row| {
        Ok(Worktree {
            id: row.get(0)?,
            path: row.get(1)?,
            name: row.get(2)?,
        })
    })?;
    Ok(entries.collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn find_worktree(state: &Path, id: &str) -> Result<Worktree> {
    worktrees(state)?
        .into_iter()
        .find(|entry| entry.id == id)
        .context("Unknown worktree")
}

pub fn register(state: &Path, path: &Path) -> Result<Worktree> {
    let root = crate::repository::root(path)?;
    let path = root
        .to_str()
        .context("Worktree path must be UTF-8")?
        .to_owned();
    let name = root
        .file_name()
        .context("Worktree name unavailable")?
        .to_string_lossy()
        .into_owned();
    let connection = gateway_database(state)?;
    connection.execute(
        "INSERT OR IGNORE INTO worktrees VALUES (?1, ?2, ?3)",
        params![uuid::Uuid::new_v4().to_string(), path, name],
    )?;
    Ok(connection.query_row(
        "SELECT id, path, name FROM worktrees WHERE path=?1",
        [path],
        |row| {
            Ok(Worktree {
                id: row.get(0)?,
                path: row.get(1)?,
                name: row.get(2)?,
            })
        },
    )?)
}

pub fn mint_ticket(state: &Path) -> Result<String> {
    let token = secret();
    let connection = gateway_database(state)?;
    connection.execute("DELETE FROM tickets WHERE expires<=?1", [now()])?;
    connection.execute(
        "INSERT INTO tickets VALUES (?1, ?2)",
        params![digest(token.as_bytes()), now() + 60],
    )?;
    Ok(token)
}

pub fn exchange_ticket(state: &Path, ticket: &str) -> Result<Option<String>> {
    let mut connection = gateway_database(state)?;
    let transaction =
        connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let accepted = transaction.execute(
        "DELETE FROM tickets WHERE hash=?1 AND expires>?2",
        params![digest(ticket.as_bytes()), now()],
    )?;
    if accepted == 0 {
        return Ok(None);
    }
    let token = secret();
    transaction.execute(
        "INSERT INTO sessions VALUES (?1, ?2)",
        params![digest(token.as_bytes()), now() + 30 * 24 * 3600],
    )?;
    transaction.commit()?;
    Ok(Some(token))
}

pub fn authenticated(state: &Path, token: &str) -> Result<bool> {
    let connection = gateway_database(state)?;
    Ok(connection
        .query_row(
            "SELECT 1 FROM sessions WHERE hash=?1 AND expires>?2",
            params![digest(token.as_bytes()), now()],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

pub fn worktree_state(state: &Path, id: &str) -> PathBuf {
    state.join("worktrees").join(id)
}
