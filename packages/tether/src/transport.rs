use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::UnixStream,
};

use crate::model::{MAX_FRAME, VERSION};

#[derive(Serialize, Deserialize)]
pub struct Request {
    pub jsonrpc: String,
    pub id: u64,
    pub version: String,
    pub method: String,
    pub params: Value,
}

#[derive(Serialize, Deserialize)]
pub struct Reply {
    pub jsonrpc: String,
    pub id: u64,
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Serialize, Deserialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
}

impl Request {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.jsonrpc == "2.0", "JSON-RPC 2.0 required");
        ensure!(self.version == VERSION, "Tether release mismatch");
        Ok(())
    }
}

impl Reply {
    pub fn into_result(self, id: u64) -> Result<Value> {
        ensure!(
            self.jsonrpc == "2.0" && self.id == id,
            "Invalid JSON-RPC response identity"
        );
        ensure!(self.version == VERSION, "Tether release mismatch");
        match (self.result, self.error) {
            (Some(result), None) => Ok(result),
            (_, Some(error)) => anyhow::bail!(error.message),
            _ => anyhow::bail!("Invalid service response"),
        }
    }

    pub fn outcome(id: u64, outcome: Result<Value>) -> Self {
        let (result, error) = match outcome {
            Ok(result) => (Some(result), None),
            Err(error) => (
                None,
                Some(RpcError {
                    code: -32000,
                    message: error.to_string(),
                }),
            ),
        };
        Self {
            jsonrpc: "2.0".into(),
            id,
            version: VERSION.into(),
            result,
            error,
        }
    }
}

pub async fn respond(
    stream: &mut (impl AsyncWrite + Unpin),
    id: u64,
    outcome: Result<Value>,
) -> Result<()> {
    let mut reply = Reply::outcome(id, outcome);
    if serde_json::to_vec(&reply)?.len() > MAX_FRAME {
        reply = Reply::outcome(
            id,
            Err(anyhow::anyhow!("Response exceeds the initial 1 MiB limit")),
        );
    }
    write(stream, &reply).await
}

pub async fn read<T: serde::de::DeserializeOwned>(
    stream: &mut (impl AsyncRead + Unpin),
) -> Result<T> {
    let length = stream.read_u32().await? as usize;
    ensure!(length <= MAX_FRAME, "Frame exceeds 1 MiB");
    let mut bytes = vec![0; length];
    stream.read_exact(&mut bytes).await?;
    Ok(serde_json::from_slice(&bytes)?)
}

pub async fn write<T: Serialize>(stream: &mut (impl AsyncWrite + Unpin), value: &T) -> Result<()> {
    let bytes = serde_json::to_vec(value)?;
    ensure!(bytes.len() <= MAX_FRAME, "Frame exceeds 1 MiB");
    stream.write_u32(bytes.len() as u32).await?;
    stream.write_all(&bytes).await?;
    Ok(())
}

pub async fn call(socket: &Path, method: &str, params: Value) -> Result<Value> {
    static NEXT_ID: AtomicU64 = AtomicU64::new(1);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let budget = if matches!(method, "analysisSource" | "inspect") {
        50
    } else {
        15
    };
    tokio::time::timeout(Duration::from_secs(budget), async {
        let mut stream = UnixStream::connect(socket).await?;
        write(
            &mut stream,
            &Request {
                jsonrpc: "2.0".into(),
                id,
                version: VERSION.into(),
                method: method.into(),
                params,
            },
        )
        .await?;
        let reply: Reply = read(&mut stream).await?;
        reply.into_result(id)
    })
    .await?
}
