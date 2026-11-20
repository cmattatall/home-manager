use anyhow::{Context, Result, bail, ensure};
use fs2::FileExt;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::File,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::Mutex,
};
use url::Url;

use crate::{
    model::{AnalysisSource, Inspection, Selection, SourceLocation, Symbol},
    repository,
    service::Store,
    state,
};

struct Project {
    context: String,
    files: BTreeMap<String, String>,
}

pub struct Analysis {
    root: PathBuf,
    state_directory: PathBuf,
    session: Mutex<Option<Lsp>>,
}

struct Lsp {
    _child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next_id: u64,
    context: String,
    capabilities: Value,
}

impl Project {
    fn read(root: &Path) -> Result<Self> {
        let head = repository::head(root)?;
        let mut files = BTreeMap::new();
        let mut size = 0;
        for path in repository::files(root)? {
            let name = Path::new(&path)
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("");
            if !path.ends_with(".go")
                && !matches!(name, "go.mod" | "go.sum" | "go.work" | "go.work.sum")
            {
                continue;
            }
            if let Some(text) = repository::working_source(root, &path)? {
                size += text.len();
                ensure!(
                    size <= 16 * 1024 * 1024,
                    "Go analysis exceeds this slice's 16 MiB project capture limit"
                );
                files.insert(path, text);
            }
        }
        let context = state::digest(&serde_json::to_vec(&(&head, &files))?);
        Ok(Self { context, files })
    }
}

impl Analysis {
    pub fn new(root: PathBuf, state_directory: PathBuf) -> Self {
        Self {
            root,
            state_directory,
            session: Mutex::new(None),
        }
    }

    async fn project(&self) -> Result<Project> {
        let root = self.root.clone();
        tokio::task::spawn_blocking(move || Project::read(&root)).await?
    }

    pub async fn execute(
        &self,
        store: Arc<Store>,
        operation: &str,
        params: Value,
    ) -> Result<Value> {
        ensure!(
            store.analysis_allowed()?,
            "Enable Go analysis for this trusted worktree first. gopls can invoke the Go toolchain and access dependencies"
        );
        let path = params["path"].as_str().context("Go source path required")?;
        ensure!(path.ends_with(".go"), "Go analysis requires a .go file");
        let project = self.project().await?;
        let text = project
            .files
            .get(path)
            .context("Go source is unavailable in this worktree")?;
        let source = store.capture(path, text.clone())?;
        if operation == "inspect" {
            ensure!(
                params["context"].as_str() == Some(&project.context)
                    && params["sourceId"].as_str() == Some(&source.id),
                "Analysis context changed. Explore current version again"
            );
        }
        let mut guard = self.session.lock().await;
        let previous = guard.take();
        let mut lsp = match previous {
            Some(lsp) if lsp.context == project.context => lsp,
            _ => Lsp::start(&self.root, &self.state_directory, &project).await?,
        };
        let result =
            if operation == "analysisSource" {
                // The first semantic response establishes the cold-start readiness boundary.
                lsp.request(
                    "textDocument/documentSymbol",
                    json!({"textDocument": {"uri": file_uri(&self.root, path)?}}),
                )
                .await?;
                json!(AnalysisSource {
                    source,
                    context: project.context.clone()
                })
            } else {
                let kind = params["kind"]
                    .as_str()
                    .context("Inspection kind required")?;
                let (method, capability) = match kind {
                    "hover" => ("textDocument/hover", "hoverProvider"),
                    "definition" => ("textDocument/definition", "definitionProvider"),
                    "typeDefinition" => ("textDocument/typeDefinition", "typeDefinitionProvider"),
                    "implementation" => ("textDocument/implementation", "implementationProvider"),
                    "references" => ("textDocument/references", "referencesProvider"),
                    "symbols" => ("textDocument/documentSymbol", "documentSymbolProvider"),
                    _ => bail!("Unsupported Go inspection"),
                };
                ensure!(
                    !matches!(
                        lsp.capabilities.get(capability),
                        None | Some(Value::Null) | Some(Value::Bool(false))
                    ),
                    "gopls does not support {kind}"
                );
                let line: u32 = params["line"].as_str().context("Line required")?.parse()?;
                let column: u32 = params["column"]
                    .as_str()
                    .context("Column required")?
                    .parse()?;
                let position = Selection {
                    start_line_number: line,
                    end_line_number: line,
                    start_column: column,
                    end_column: column,
                };
                crate::service::selected_text(text, &position)?;
                let response = lsp.request(method, json!({
                "textDocument": {"uri": file_uri(&self.root, path)?},
                "position": {"line": line - 1, "character": column - 1},
                "context": {"includeDeclaration": params["includeDeclaration"] != "false"},
            })).await?;
                json!(self.normalize(&store, &project, kind, response)?)
            };
        ensure!(
            self.project().await?.context == project.context,
            "Source changed during Go analysis. Explore current version again"
        );
        *guard = Some(lsp);
        Ok(result)
    }

    fn normalize(
        &self,
        store: &Store,
        project: &Project,
        kind: &str,
        response: Value,
    ) -> Result<Inspection> {
        let mut result = Inspection {
            context: project.context.clone(),
            hover: Vec::new(),
            locations: Vec::new(),
            symbols: Vec::new(),
        };
        if response.is_null() {
            return Ok(result);
        }
        if kind == "hover" {
            let contents = &response["contents"];
            let items = contents
                .as_array()
                .cloned()
                .unwrap_or_else(|| vec![contents.clone()]);
            for item in items {
                if let Some(text) = item.as_str() {
                    result.hover.push(text.to_owned());
                } else if let Some(text) = item["value"].as_str() {
                    result.hover.push(text.to_owned());
                }
            }
        } else if kind == "symbols" {
            result.symbols = response
                .as_array()
                .context("Invalid Go symbols")?
                .iter()
                .map(symbol)
                .collect::<Result<_>>()?;
        } else {
            let locations = response
                .as_array()
                .cloned()
                .unwrap_or_else(|| vec![response]);
            ensure!(
                locations.len() <= 100,
                "Go result exceeds 100 locations. Narrow the query"
            );
            for location in locations {
                let uri = location["uri"]
                    .as_str()
                    .or_else(|| location["targetUri"].as_str())
                    .context("Invalid Go location URI")?;
                let absolute = Url::parse(uri)?
                    .to_file_path()
                    .map_err(|_| anyhow::anyhow!("Go location must be a file"))?;
                let path = absolute.strip_prefix(&self.root).context("Go target is outside this worktree. Dependency source navigation is pending")?.to_str().context("Go path must be UTF-8")?;
                let text = project
                    .files
                    .get(path)
                    .context("Go target is outside the captured project sources")?;
                let range = location
                    .get("targetSelectionRange")
                    .unwrap_or(&location["range"]);
                let selection = selection(range)?;
                crate::service::selected_text(text, &selection)?;
                result.locations.push(SourceLocation {
                    source: store.capture(path, text.clone())?,
                    selection,
                });
            }
        }
        Ok(result)
    }
}

fn selection(range: &Value) -> Result<Selection> {
    let coordinate = |endpoint: &str, field: &str| -> Result<u32> {
        let value = range[endpoint][field]
            .as_u64()
            .context("Invalid Go source range")?;
        u32::try_from(value)?
            .checked_add(1)
            .context("Go range overflow")
    };
    Ok(Selection {
        start_line_number: coordinate("start", "line")?,
        start_column: coordinate("start", "character")?,
        end_line_number: coordinate("end", "line")?,
        end_column: coordinate("end", "character")?,
    })
}

fn symbol(value: &Value) -> Result<Symbol> {
    Ok(Symbol {
        name: value["name"]
            .as_str()
            .context("Invalid Go symbol name")?
            .into(),
        kind: value["kind"].as_u64().context("Invalid Go symbol kind")? as u32,
        range: selection(&value["range"])?,
        selection_range: selection(&value["selectionRange"])?,
        children: value["children"]
            .as_array()
            .map(|children| children.iter().map(symbol).collect())
            .transpose()?
            .unwrap_or_default(),
    })
}

fn file_uri(root: &Path, path: &str) -> Result<String> {
    Ok(Url::from_file_path(root.join(path))
        .map_err(|_| anyhow::anyhow!("Invalid Go source path"))?
        .to_string())
}

impl Lsp {
    async fn start(root: &Path, state_directory: &Path, project: &Project) -> Result<Self> {
        let mut admission = None;
        for slot in 0..2 {
            let file = File::options()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(state_directory.join(format!("go-start-{slot}.lock")))?;
            match file.try_lock_exclusive() {
                Ok(()) => {
                    admission = Some(file);
                    break;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error.into()),
            }
        }
        let _admission = admission
            .context("Go startup slots are busy. Retry after another worktree finishes starting")?;
        let mut child = Command::new("gopls")
            .arg("serve")
            .current_dir(root)
            .env("GOTOOLCHAIN", "local")
            .env("GOPROXY", "off")
            .env("GOSUMDB", "off")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .context("Cannot start gopls. Install gopls and Go on the execution machine")?;
        let input = child.stdin.take().context("gopls stdin unavailable")?;
        let output = BufReader::new(child.stdout.take().context("gopls stdout unavailable")?);
        let mut lsp = Self {
            _child: child,
            input,
            output,
            next_id: 0,
            context: project.context.clone(),
            capabilities: Value::Null,
        };
        let root_uri = Url::from_directory_path(root)
            .map_err(|_| anyhow::anyhow!("Invalid Go project root"))?;
        let initialized = lsp.request("initialize", json!({
            "processId": std::process::id(), "clientInfo": {"name": "Tether", "version": crate::model::VERSION},
            "rootUri": root_uri.as_str(), "workspaceFolders": [{"uri": root_uri.as_str(), "name": "worktree"}],
            "capabilities": {"general": {"positionEncodings": ["utf-16"]}, "textDocument": {
                "hover": {"contentFormat": ["markdown", "plaintext"]}, "definition": {"linkSupport": true},
                "documentSymbol": {"hierarchicalDocumentSymbolSupport": true}
            }}
        })).await?;
        lsp.capabilities = initialized["capabilities"].clone();
        ensure!(
            lsp.capabilities["positionEncoding"]
                .as_str()
                .unwrap_or("utf-16")
                == "utf-16",
            "Unsupported gopls position encoding"
        );
        lsp.notify("initialized", json!({})).await?;
        for (path, text) in &project.files {
            if path.ends_with(".go") {
                lsp.notify("textDocument/didOpen", json!({"textDocument": {
                    "uri": file_uri(root, path)?, "languageId": "go", "version": 1, "text": text,
                }})).await?;
            }
        }
        let path = project
            .files
            .keys()
            .find(|path| path.ends_with(".go"))
            .context("Go project has no source files")?;
        lsp.request(
            "textDocument/documentSymbol",
            json!({"textDocument": {"uri": file_uri(root, path)?}}),
        )
        .await?;
        Ok(lsp)
    }

    async fn send(&mut self, message: Value) -> Result<()> {
        let bytes = serde_json::to_vec(&message)?;
        self.input
            .write_all(format!("Content-Length: {}\r\n\r\n", bytes.len()).as_bytes())
            .await?;
        self.input.write_all(&bytes).await?;
        self.input.flush().await?;
        Ok(())
    }

    async fn receive(&mut self) -> Result<Value> {
        let mut length = None;
        let mut header_bytes = 0;
        loop {
            let mut line = Vec::new();
            let count = (&mut self.output)
                .take(8193)
                .read_until(b'\n', &mut line)
                .await?;
            ensure!(count > 0, "gopls exited. Retry Go analysis");
            header_bytes += count;
            ensure!(header_bytes <= 8192, "gopls header exceeds 8 KiB");
            if line == b"\r\n" {
                break;
            }
            let line = std::str::from_utf8(&line)?;
            if let Some((name, value)) = line.split_once(':')
                && name.eq_ignore_ascii_case("Content-Length")
            {
                length = Some(value.trim().parse::<usize>()?);
            }
        }
        let length = length.context("Missing gopls Content-Length")?;
        ensure!(length <= 16 * 1024 * 1024, "gopls message exceeds 16 MiB");
        let mut bytes = vec![0; length];
        self.output.read_exact(&mut bytes).await?;
        Ok(serde_json::from_slice(&bytes)?)
    }

    async fn notify(&mut self, method: &str, params: Value) -> Result<()> {
        self.send(json!({"jsonrpc": "2.0", "method": method, "params": params}))
            .await
    }

    async fn request(&mut self, method: &str, params: Value) -> Result<Value> {
        self.next_id += 1;
        let id = self.next_id;
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))
            .await?;
        loop {
            let message = self.receive().await?;
            if let Some(server_method) = message["method"].as_str() {
                if let Some(server_id) = message.get("id") {
                    let reply = match server_method {
                        "window/workDoneProgress/create" => {
                            json!({"jsonrpc": "2.0", "id": server_id, "result": null})
                        }
                        _ => {
                            json!({"jsonrpc": "2.0", "id": server_id, "error": {"code": -32601, "message": "Unsupported client operation"}})
                        }
                    };
                    self.send(reply).await?;
                }
                continue;
            }
            if message["id"] != id {
                continue;
            }
            if let Some(error) = message.get("error") {
                bail!("gopls {method}: {error}");
            }
            return message
                .get("result")
                .cloned()
                .context("Missing gopls response");
        }
    }
}
