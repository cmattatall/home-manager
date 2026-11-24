use anyhow::{Context, Result, bail, ensure};
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{Read, Write},
    path::PathBuf,
    sync::{Arc, Mutex, mpsc},
    time::{Duration, Instant},
};
use tether_terminal::{Dimensions, FrameSender, FrameStamp, MAX_INPUT_BYTES, Terminal};

use crate::{
    model::{ManagedLaunch, ManagedSession, Worktree},
    state,
};

pub struct Sessions {
    directory: PathBuf,
    worktree: Worktree,
    running: Mutex<HashMap<String, Arc<Mutex<Runtime>>>>,
}

struct Runtime {
    record: ManagedSession,
    terminal: Terminal,
    master: Box<dyn MasterPty + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    writer: Option<mpsc::SyncSender<Vec<u8>>>,
    attachments: HashMap<String, Attachment>,
    controller: Option<String>,
    generation: u64,
}

struct Attachment {
    sender: FrameSender,
    received: Option<FrameStamp>,
    expires: Instant,
}

fn pty_size(dimensions: Dimensions) -> PtySize {
    PtySize {
        rows: dimensions.rows as u16,
        cols: dimensions.columns as u16,
        pixel_width: 0,
        pixel_height: 0,
    }
}

fn save(directory: &std::path::Path, record: &ManagedSession) -> Result<()> {
    state::database(&directory.join("sessions.sqlite"))?.execute(
        "INSERT INTO sessions(id,payload) VALUES (?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
        params![record.launch.id, serde_json::to_string(record)?],
    )?;
    Ok(())
}

impl Sessions {
    pub fn new(directory: PathBuf, worktree: Worktree) -> Result<Self> {
        state::database(&directory.join("sessions.sqlite"))?.execute_batch(
            "CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, payload TEXT NOT NULL);",
        )?;
        state::database(&directory.join("sessions.sqlite"))?.execute(
            "UPDATE sessions SET payload=json_set(payload, '$.status', 'lost', '$.detail', ?1)
             WHERE json_extract(payload, '$.status') IN ('starting', 'running')",
            ["The owning service stopped. Check surviving processes before starting another session."],
        )?;
        let sessions = Self {
            directory,
            worktree,
            running: Mutex::new(HashMap::new()),
        };
        Ok(sessions)
    }

    fn list(&self) -> Result<Vec<ManagedSession>> {
        let connection = state::database(&self.directory.join("sessions.sqlite"))?;
        let mut statement = connection.prepare(
            "SELECT payload FROM sessions
             ORDER BY json_extract(payload, '$.status') IN ('starting', 'running') DESC, rowid DESC
             LIMIT 100",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .map(|row| Ok(serde_json::from_str(&row?)?))
            .collect()
    }

    pub fn active(&self) -> bool {
        self.running
            .lock()
            .unwrap()
            .values()
            .any(|runtime| runtime.lock().unwrap().record.status == "running")
    }

    pub fn expire(&self) {
        let now = Instant::now();
        self.running.lock().unwrap().retain(|_, runtime| {
            let mut runtime = runtime.lock().unwrap();
            runtime.expire(now);
            runtime.record.status == "running" || !runtime.attachments.is_empty()
        });
    }

    fn launch(&self, launch: ManagedLaunch) -> Result<ManagedSession> {
        uuid::Uuid::parse_str(&launch.id).context("Launch ID must be a UUID")?;
        let terminal = Terminal::new(launch.dimensions)?;
        let mut running = self.running.lock().unwrap();
        let previous: Option<String> = state::database(&self.directory.join("sessions.sqlite"))?
            .query_row(
                "SELECT payload FROM sessions WHERE id=?1",
                [&launch.id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(previous) = previous {
            let previous: ManagedSession = serde_json::from_str(&previous)?;
            ensure!(
                previous.launch == launch,
                "Launch ID already belongs to another request"
            );
            return Ok(previous);
        }
        ensure!(
            running.len() < 4,
            "This worktree supports four managed terminal runtimes"
        );
        let mut record = ManagedSession {
            launch,
            runtime: None,
            status: "starting".into(),
            detail: String::new(),
        };
        save(&self.directory, &record)?;
        let started = (|| -> Result<_> {
            let pair = native_pty_system().openpty(pty_size(record.launch.dimensions))?;
            let mut command = CommandBuilder::new("amp");
            command.cwd(&self.worktree.path);
            command.env("TERM", "xterm-256color");
            let reader = pair.master.try_clone_reader()?;
            let writer = pair.master.take_writer()?;
            let child = pair
                .slave
                .spawn_command(command)
                .context("Could not start Amp. Install and authenticate Amp on this machine")?;
            drop(pair.slave);
            Ok((pair.master, reader, writer, child))
        })();
        let (master, mut reader, mut writer, mut child) = match started {
            Ok(started) => started,
            Err(error) => {
                record.status = "failed".into();
                record.detail = error.to_string();
                save(&self.directory, &record)?;
                return Ok(record);
            }
        };
        record.runtime = Some(terminal.frame()?.stamp.runtime.to_string());
        record.status = "running".into();
        if let Err(error) = save(&self.directory, &record) {
            child.kill()?;
            child.wait()?;
            return Err(error);
        }
        let (input, inputs) = mpsc::sync_channel::<Vec<u8>>(16);
        let runtime = Arc::new(Mutex::new(Runtime {
            record: record.clone(),
            terminal,
            master,
            killer: child.clone_killer(),
            writer: Some(input.clone()),
            attachments: HashMap::new(),
            controller: None,
            generation: 0,
        }));
        running.insert(record.launch.id.clone(), runtime.clone());
        std::thread::spawn(move || {
            for bytes in inputs {
                if writer.write_all(&bytes).is_err() {
                    break;
                }
            }
        });
        let output = runtime.clone();
        std::thread::spawn(move || {
            let mut bytes = [0; MAX_INPUT_BYTES];
            loop {
                let length = match reader.read(&mut bytes) {
                    Ok(0) | Err(_) => break,
                    Ok(length) => length,
                };
                let mut runtime = output.lock().unwrap();
                match runtime.terminal.advance(&bytes[..length]) {
                    Ok(replies) if !replies.is_empty() => {
                        if input.try_send(replies).is_err() {
                            runtime.record.detail = "Terminal reply queue overflowed".into();
                        }
                    }
                    Ok(_) => {}
                    Err(error) => runtime.record.detail = error.to_string(),
                }
            }
        });
        let directory = self.directory.clone();
        std::thread::spawn(move || {
            let result = child.wait();
            let mut runtime = runtime.lock().unwrap();
            runtime.record.status = "exited".into();
            runtime.record.detail = match result {
                Ok(status) => format!("Amp exited: {status}"),
                Err(error) => format!("Could not observe Amp exit: {error}"),
            };
            runtime.writer = None;
            runtime.controller = None;
            if let Err(error) = save(&directory, &runtime.record) {
                eprintln!("Could not persist managed session exit: {error}");
            }
        });
        Ok(record)
    }

    pub fn execute(&self, method: &str, params: Value) -> Result<Value> {
        if method == "managedSessions" {
            return Ok(json!(self.list()?));
        }
        if method == "launchSession" {
            return Ok(json!(self.launch(serde_json::from_value(params)?)?));
        }
        let id = params["session"]
            .as_str()
            .context("Managed session ID required")?;
        let runtime = self
            .running
            .lock()
            .unwrap()
            .get(id)
            .cloned()
            .context("Managed runtime is unavailable. Refresh sessions")?;
        let mut runtime = runtime.lock().unwrap();
        runtime.expire(Instant::now());
        if method == "attachTerminal" {
            ensure!(
                runtime.attachments.len() < 4,
                "This terminal supports four attachments"
            );
            let attachment = uuid::Uuid::new_v4().to_string();
            runtime.attachments.insert(
                attachment.clone(),
                Attachment {
                    sender: FrameSender::default(),
                    received: None,
                    expires: Instant::now() + Duration::from_secs(30),
                },
            );
            if runtime.controller.is_none() {
                runtime.controller = Some(attachment.clone());
                runtime.generation += 1;
            }
            return Ok(
                json!({"attachment": attachment, "runtime": runtime.record.runtime,
                "generation": runtime.generation, "control": runtime.controller.as_ref() == Some(&attachment)}),
            );
        }
        let attachment = params["attachment"]
            .as_str()
            .context("Terminal attachment required")?;
        ensure!(
            runtime.attachments.contains_key(attachment),
            "Terminal attachment expired. Reconnect"
        );
        if method == "detachTerminal" {
            runtime.remove(attachment);
            return Ok(json!({}));
        }
        if method == "claimTerminal" {
            runtime.controller = Some(attachment.into());
            runtime.generation += 1;
            let delivery = runtime.attachments.get_mut(attachment).unwrap();
            delivery.received = None;
            delivery.sender = FrameSender::default();
            return Ok(json!({"generation": runtime.generation}));
        }
        if matches!(method, "terminalInput" | "resizeTerminal" | "stopSession") {
            ensure!(
                runtime.controller.as_deref() == Some(attachment)
                    && params["generation"].as_u64() == Some(runtime.generation),
                "Terminal control changed"
            );
            ensure!(
                runtime.attachments[attachment].received.is_some(),
                "Acknowledge a fresh terminal frame before input"
            );
            ensure!(
                runtime.record.status == "running",
                "Managed process has exited"
            );
            match method {
                "terminalInput" => {
                    let text = params["text"].as_str().context("Terminal input required")?;
                    ensure!(
                        !text.is_empty() && text.len() <= MAX_INPUT_BYTES,
                        "Terminal input supports 1–4096 bytes"
                    );
                    runtime
                        .writer
                        .as_ref()
                        .context("Terminal input closed")?
                        .try_send(text.as_bytes().to_vec())
                        .context("Terminal input queue is full or closed")?;
                }
                "resizeTerminal" => {
                    let dimensions: Dimensions =
                        serde_json::from_value(params["dimensions"].clone())?;
                    dimensions.validate()?;
                    runtime.master.resize(pty_size(dimensions))?;
                    runtime.terminal.resize(dimensions)?;
                    let delivery = runtime.attachments.get_mut(attachment).unwrap();
                    delivery.received = None;
                    delivery.sender = FrameSender::default();
                }
                "stopSession" => runtime.killer.kill()?,
                _ => unreachable!(),
            }
            return Ok(json!({}));
        }
        let Runtime {
            terminal,
            attachments,
            generation,
            controller,
            record,
            ..
        } = &mut *runtime;
        let delivery = attachments.get_mut(attachment).unwrap();
        match method {
            "terminalFrame" => {
                let (stamp, length) = delivery.sender.start(terminal)?;
                Ok(json!({"stamp": stamp, "length": length}))
            }
            "terminalChunk" => {
                let offset = params["offset"].as_u64().context("Chunk offset required")? as usize;
                Ok(json!({"bytes": delivery.sender.chunk(offset)?}))
            }
            "terminalAck" => {
                let stamp = serde_json::from_value(params["stamp"].clone())?;
                let displayed = params["displayed"]
                    .as_bool()
                    .context("Display receipt required")?;
                delivery.sender.acknowledge(stamp)?;
                delivery.received = displayed.then_some(stamp);
                delivery.expires = Instant::now() + Duration::from_secs(30);
                Ok(json!({}))
            }
            "terminalHeartbeat" => {
                if params["paused"] == true {
                    delivery.received = None;
                }
                delivery.expires = Instant::now() + Duration::from_secs(30);
                Ok(
                    json!({"generation": generation, "control": controller.as_deref() == Some(attachment), "status": record.status}),
                )
            }
            _ => bail!("Unknown managed terminal operation"),
        }
    }
}

impl Runtime {
    fn remove(&mut self, attachment: &str) {
        self.attachments.remove(attachment);
        if self.controller.as_deref() == Some(attachment) {
            self.controller = None;
            self.generation += 1;
        }
    }

    fn expire(&mut self, now: Instant) {
        let expired: Vec<String> = self
            .attachments
            .iter_mut()
            .filter_map(|(id, attachment)| {
                (attachment.sender.expire(now) || now >= attachment.expires).then(|| id.clone())
            })
            .collect();
        for id in expired {
            self.remove(&id);
        }
    }
}
