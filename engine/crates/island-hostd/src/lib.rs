use std::io::{BufRead, BufReader, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow};
use codex_island_proto::{
    AppServerHealth, AppServerLifecycleState, AuthToken, ClientCommand, ENGINE_PROTOCOL_VERSION,
    EngineSnapshot, ErrorCode, HostCapabilities, HostHealthSnapshot, HostHealthStatus,
    HostPlatform, PairedDeviceRecord, PairingSession, PairingSessionStatus, ProtocolError,
    ServerEvent,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tungstenite::{Message, WebSocket, accept};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnConfig {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
}

impl SpawnConfig {
    pub fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            cwd: None,
        }
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args = args.into_iter().map(Into::into).collect();
        self
    }

    pub fn cwd(mut self, cwd: impl Into<PathBuf>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChildEvent {
    StdoutLine(String),
    StderrLine(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExitMetadata {
    pub code: Option<i32>,
    pub success: bool,
}

impl ExitMetadata {
    fn from_status(status: ExitStatus) -> Self {
        Self {
            code: status.code(),
            success: status.success(),
        }
    }
}

pub struct ManagedChild {
    child: Child,
    stdin: Option<ChildStdin>,
    events: Receiver<ChildEvent>,
    stdout_thread: Option<JoinHandle<()>>,
    stderr_thread: Option<JoinHandle<()>>,
    exit_status: Option<ExitMetadata>,
}

impl ManagedChild {
    pub fn spawn(config: &SpawnConfig) -> Result<Self> {
        let mut command = Command::new(&config.program);
        command.args(&config.args);
        if let Some(cwd) = &config.cwd {
            command.current_dir(cwd);
        }
        command.stdin(Stdio::piped());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());

        let mut child = command.spawn().with_context(|| {
            format!(
                "failed to spawn child process: {}",
                config.program.display()
            )
        })?;

        let stdin = child.stdin.take();
        let stdout = child.stdout.take().context("child stdout was not piped")?;
        let stderr = child.stderr.take().context("child stderr was not piped")?;

        let (sender, receiver) = mpsc::channel();
        let stdout_thread = spawn_line_reader(stdout, sender.clone(), StreamKind::Stdout);
        let stderr_thread = spawn_line_reader(stderr, sender, StreamKind::Stderr);

        Ok(Self {
            child,
            stdin,
            events: receiver,
            stdout_thread: Some(stdout_thread),
            stderr_thread: Some(stderr_thread),
            exit_status: None,
        })
    }

    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    pub fn send_line(&mut self, line: &str) -> Result<()> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or_else(|| anyhow!("child stdin is closed"))?;
        stdin
            .write_all(line.as_bytes())
            .context("failed to write stdin payload")?;
        stdin
            .write_all(b"\n")
            .context("failed to write stdin newline")?;
        stdin.flush().context("failed to flush child stdin")?;
        Ok(())
    }

    pub fn close_stdin(&mut self) {
        self.stdin.take();
    }

    pub fn try_recv_event(&self) -> std::result::Result<ChildEvent, mpsc::TryRecvError> {
        self.events.try_recv()
    }

    pub fn wait(&mut self) -> Result<ExitMetadata> {
        if let Some(metadata) = self.exit_status.clone() {
            return Ok(metadata);
        }

        let status = self.child.wait().context("failed waiting for child")?;
        let metadata = ExitMetadata::from_status(status);
        self.exit_status = Some(metadata.clone());
        self.join_reader_threads();
        Ok(metadata)
    }

    pub fn poll_exit(&mut self) -> Result<Option<ExitMetadata>> {
        if let Some(metadata) = self.exit_status.clone() {
            return Ok(Some(metadata));
        }

        let Some(status) = self.child.try_wait().context("failed polling child exit")? else {
            return Ok(None);
        };

        let metadata = ExitMetadata::from_status(status);
        self.exit_status = Some(metadata.clone());
        self.join_reader_threads();
        Ok(Some(metadata))
    }

    pub fn stop(&mut self) -> Result<ExitMetadata> {
        self.close_stdin();
        if self.poll_exit()?.is_none() {
            self.child.kill().context("failed to terminate child")?;
        }
        self.wait()
    }

    fn join_reader_threads(&mut self) {
        if let Some(handle) = self.stdout_thread.take() {
            let _ = handle.join();
        }
        if let Some(handle) = self.stderr_thread.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for ManagedChild {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

#[derive(Copy, Clone)]
enum StreamKind {
    Stdout,
    Stderr,
}

fn spawn_line_reader<R>(reader: R, sender: Sender<ChildEvent>, stream: StreamKind) -> JoinHandle<()>
where
    R: std::io::Read + Send + 'static,
{
    thread::spawn(move || {
        let mut reader = BufReader::new(reader);
        let mut buffer = Vec::new();

        loop {
            buffer.clear();
            match reader.read_until(b'\n', &mut buffer) {
                Ok(0) => break,
                Ok(_) => {
                    if buffer.last() == Some(&b'\n') {
                        buffer.pop();
                    }
                    if buffer.last() == Some(&b'\r') {
                        buffer.pop();
                    }
                    if buffer.is_empty() {
                        continue;
                    }
                    let line = String::from_utf8_lossy(&buffer).into_owned();
                    let event = match stream {
                        StreamKind::Stdout => ChildEvent::StdoutLine(line),
                        StreamKind::Stderr => ChildEvent::StderrLine(line),
                    };
                    if sender.send(event).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    })
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn codex_app_server_shell_command(cwd: Option<&Path>) -> String {
    match cwd.and_then(|value| value.to_str()).map(str::trim).filter(|value| !value.is_empty()) {
        Some(cwd) => format!(
            "exec codex --cd {} app-server --listen stdio://",
            shell_quote(cwd)
        ),
        None => "exec codex app-server --listen stdio://".to_string(),
    }
}

pub fn codex_app_server_command(shell: &Path) -> SpawnConfig {
    codex_app_server_command_with_cwd(shell, None)
}

pub fn codex_app_server_command_with_cwd(shell: &Path, cwd: Option<&Path>) -> SpawnConfig {
    let mut config = SpawnConfig::new(shell).args(vec![
        "-lc".to_string(),
        codex_app_server_shell_command(cwd),
    ]);
    if let Some(cwd) = cwd {
        config = config.cwd(cwd);
    }
    config
}

#[derive(Debug, Clone)]
pub struct HostDaemonConfig {
    pub host_id: String,
    pub hostname: String,
    pub platform: HostPlatform,
    pub spawn: SpawnConfig,
    pub state_dir: PathBuf,
}

impl HostDaemonConfig {
    pub fn local(shell: &Path) -> Self {
        Self {
            host_id: "local-host".into(),
            hostname: hostname_fallback(),
            platform: current_platform(),
            spawn: codex_app_server_command(shell),
            state_dir: default_state_dir(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct HostStore {
    active_pairing: Option<PairingSession>,
    paired_devices: Vec<StoredDeviceRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredDeviceRecord {
    device: PairedDeviceRecord,
    token: AuthToken,
}

pub struct HostDaemon {
    config: HostDaemonConfig,
    child: Option<ManagedChild>,
    store: HostStore,
    started_at: String,
    observed_at: String,
    last_error: Option<String>,
    last_exit_code: Option<i32>,
    restart_count: u32,
    next_event_id: u64,
    authenticated_device_id: Option<String>,
}

impl HostDaemon {
    pub fn new(config: HostDaemonConfig) -> Self {
        let now = now_string();
        let store = load_store(&config.state_dir).unwrap_or_default();
        Self {
            config,
            child: None,
            store,
            started_at: now.clone(),
            observed_at: now,
            last_error: None,
            last_exit_code: None,
            restart_count: 0,
            next_event_id: 1,
            authenticated_device_id: None,
        }
    }

    pub fn start(&mut self) -> Vec<ServerEvent> {
        self.ensure_child_started()
    }

    pub fn stop(&mut self) -> Result<()> {
        if let Some(child) = self.child.as_mut() {
            let metadata = child.stop()?;
            self.last_exit_code = metadata.code;
        }
        self.child = None;
        self.observed_at = now_string();
        Ok(())
    }

    pub fn handle_command(&mut self, command: ClientCommand) -> Vec<ServerEvent> {
        match command {
            ClientCommand::Hello {
                protocol_version,
                auth_token,
                ..
            } => {
                if protocol_version != ENGINE_PROTOCOL_VERSION {
                    return vec![ServerEvent::Error {
                        error: ProtocolError {
                            code: ErrorCode::InvalidProtocolVersion,
                            message: format!(
                                "Unsupported protocol version {protocol_version}; expected {ENGINE_PROTOCOL_VERSION}"
                            ),
                            retryable: Some(false),
                            details: None,
                        },
                    }];
                }

                let authenticated = match auth_token {
                    Some(token) => match self.authenticate_token(&token) {
                        Some(device_id) => {
                            self.authenticated_device_id = Some(device_id);
                            true
                        }
                        None => {
                            self.authenticated_device_id = None;
                            return vec![ServerEvent::Error {
                                error: ProtocolError {
                                    code: ErrorCode::Unauthorized,
                                    message: "Invalid auth token".into(),
                                    retryable: Some(false),
                                    details: None,
                                },
                            }];
                        }
                    },
                    None => {
                        self.authenticated_device_id = None;
                        false
                    }
                };

                vec![ServerEvent::HelloAck {
                    protocol_version: ENGINE_PROTOCOL_VERSION.into(),
                    daemon_version: env!("CARGO_PKG_VERSION").into(),
                    host_id: self.config.host_id.clone(),
                    authenticated,
                }]
            }
            ClientCommand::GetSnapshot => vec![ServerEvent::Snapshot {
                snapshot: self.snapshot(),
            }],
            ClientCommand::PairStart {
                device_name,
                client_platform: _,
            } => {
                let pairing = PairingSession {
                    pairing_code: generate_pairing_code(),
                    session_id: generate_session_id("pair"),
                    status: PairingSessionStatus::Pending,
                    expires_at: now_string(),
                    device_name: Some(device_name),
                };
                self.store.active_pairing = Some(pairing.clone());
                if let Err(error) = self.persist_store() {
                    return vec![self.internal_error("Failed to persist pairing session", error)];
                }
                vec![ServerEvent::PairingStarted { pairing }]
            }
            ClientCommand::PairConfirm {
                pairing_code,
                device_name,
                client_platform,
            } => {
                let Some(active_pairing) = self.store.active_pairing.clone() else {
                    return vec![ServerEvent::Error {
                        error: ProtocolError {
                            code: ErrorCode::PairingRequired,
                            message: "No active pairing session".into(),
                            retryable: Some(true),
                            details: None,
                        },
                    }];
                };

                if active_pairing.pairing_code != pairing_code {
                    return vec![ServerEvent::Error {
                        error: ProtocolError {
                            code: ErrorCode::PairingCodeExpired,
                            message: "Pairing code is invalid".into(),
                            retryable: Some(false),
                            details: None,
                        },
                    }];
                }

                let pairing = PairingSession {
                    status: PairingSessionStatus::Confirmed,
                    device_name: Some(device_name.clone()),
                    ..active_pairing
                };
                let token = AuthToken {
                    token_id: generate_session_id("token"),
                    bearer_token: generate_session_id("bearer"),
                    expires_at: None,
                };
                let device = PairedDeviceRecord {
                    device_id: generate_session_id("device"),
                    device_name,
                    platform: client_platform,
                    created_at: now_string(),
                    last_seen_at: Some(now_string()),
                    last_ip: None,
                };
                self.store.active_pairing = None;
                self.store.paired_devices.push(StoredDeviceRecord {
                    device: device.clone(),
                    token: token.clone(),
                });
                if let Err(error) = self.persist_store() {
                    return vec![self.internal_error("Failed to persist paired device", error)];
                }
                vec![ServerEvent::PairingCompleted {
                    pairing,
                    device,
                    token,
                }]
            }
            ClientCommand::PairRevoke { device_id } => {
                if !self.is_authenticated() {
                    return vec![ServerEvent::Error {
                        error: ProtocolError {
                            code: ErrorCode::Unauthorized,
                            message: "Authenticated device token required".into(),
                            retryable: Some(false),
                            details: None,
                        },
                    }];
                }

                if !self.remove_device(&device_id) {
                    return vec![ServerEvent::Error {
                        error: ProtocolError {
                            code: ErrorCode::DeviceNotFound,
                            message: "Paired device not found".into(),
                            retryable: Some(false),
                            details: None,
                        },
                    }];
                }
                if let Err(error) = self.persist_store() {
                    return vec![self.internal_error("Failed to persist revoked device", error)];
                }
                vec![ServerEvent::PairingRevoked { device_id }]
            }
            ClientCommand::AppServerRequest {
                request_id,
                method,
                params,
            } => {
                if !self.is_authenticated() {
                    return vec![ServerEvent::Error {
                        error: ProtocolError {
                            code: ErrorCode::PairingRequired,
                            message: "Pair and authenticate before using app-server bridge".into(),
                            retryable: Some(false),
                            details: None,
                        },
                    }];
                }
                if let Err(error) = self.send_to_app_server(json!({
                    "id": request_id,
                    "method": method,
                    "params": params
                })) {
                    return vec![self.app_server_unavailable_error(error)];
                }
                Vec::new()
            }
            ClientCommand::AppServerResponse { request_id, result } => {
                if !self.is_authenticated() {
                    return vec![ServerEvent::Error {
                        error: ProtocolError {
                            code: ErrorCode::PairingRequired,
                            message: "Pair and authenticate before responding to app-server requests"
                                .into(),
                            retryable: Some(false),
                            details: None,
                        },
                    }];
                }
                if let Err(error) = self.send_to_app_server(json!({
                    "id": request_id,
                    "result": result
                })) {
                    return vec![self.app_server_unavailable_error(error)];
                }
                Vec::new()
            }
            ClientCommand::AppServerInterrupt { thread_id, turn_id } => {
                if !self.is_authenticated() {
                    return vec![ServerEvent::Error {
                        error: ProtocolError {
                            code: ErrorCode::PairingRequired,
                            message: "Pair and authenticate before interrupting app-server turns"
                                .into(),
                            retryable: Some(false),
                            details: None,
                        },
                    }];
                }
                if let Err(error) = self.send_to_app_server(json!({
                    "id": format!("interrupt-{thread_id}-{turn_id}"),
                    "method": "turn/interrupt",
                    "params": {
                        "threadId": thread_id,
                        "turnId": turn_id
                    }
                })) {
                    return vec![self.app_server_unavailable_error(error)];
                }
                Vec::new()
            }
        }
    }

    pub fn poll(&mut self) -> Vec<ServerEvent> {
        let mut events = Vec::new();

        while let Some(child) = self.child.as_ref() {
            match child.try_recv_event() {
                Ok(ChildEvent::StdoutLine(line)) => {
                    self.observed_at = now_string();
                    events.extend(self.normalize_stdout_line(&line));
                }
                Ok(ChildEvent::StderrLine(line)) => {
                    self.observed_at = now_string();
                    self.last_error = Some(line.clone());
                    events.push(ServerEvent::HostHealthChanged {
                        health: self.health_snapshot(
                            HostHealthStatus::Degraded,
                            AppServerLifecycleState::Degraded,
                        ),
                    });
                }
                Err(mpsc::TryRecvError::Empty) | Err(mpsc::TryRecvError::Disconnected) => break,
            }
        }

        if let Some(child) = self.child.as_mut() {
            if let Ok(Some(exit)) = child.poll_exit() {
                self.child = None;
                self.last_exit_code = exit.code;
                self.observed_at = now_string();
                let failed_health =
                    self.health_snapshot(HostHealthStatus::Failed, AppServerLifecycleState::Failed);
                events.push(ServerEvent::HostHealthChanged {
                    health: failed_health,
                });
                self.restart_count += 1;
                events.extend(self.ensure_child_started());
            }
        }

        events
    }

    pub fn snapshot(&self) -> EngineSnapshot {
        EngineSnapshot {
            health: self
                .health_snapshot(self.current_host_status(), self.current_app_server_state()),
            active_pairing: self.store.active_pairing.clone(),
            paired_devices: self
                .store
                .paired_devices
                .iter()
                .map(|record| record.device.clone())
                .collect(),
            active_thread_id: None,
            active_turn_id: None,
        }
    }

    fn ensure_child_started(&mut self) -> Vec<ServerEvent> {
        if self.child.is_some() {
            return Vec::new();
        }

        self.observed_at = now_string();
        match ManagedChild::spawn(&self.config.spawn) {
            Ok(child) => {
                self.child = Some(child);
                vec![ServerEvent::HostHealthChanged {
                    health: self
                        .health_snapshot(HostHealthStatus::Ready, AppServerLifecycleState::Ready),
                }]
            }
            Err(error) => {
                self.last_error = Some(error.to_string());
                vec![
                    ServerEvent::HostHealthChanged {
                        health: self.health_snapshot(
                            HostHealthStatus::Failed,
                            AppServerLifecycleState::Failed,
                        ),
                    },
                    ServerEvent::Error {
                        error: ProtocolError {
                            code: ErrorCode::AppServerUnavailable,
                            message: "Failed to start codex app-server".into(),
                            retryable: Some(true),
                            details: Some(json!({
                                "error": error.to_string()
                            })),
                        },
                    },
                ]
            }
        }
    }

    fn send_to_app_server(&mut self, payload: Value) -> Result<()> {
        if self.child.is_none() {
            let _ = self.ensure_child_started();
        }

        let child = self
            .child
            .as_mut()
            .ok_or_else(|| anyhow!("app-server child is unavailable"))?;
        child
            .send_line(&serde_json::to_string(&payload).context("serialize app-server payload")?)
            .context("send app-server line")?;
        Ok(())
    }

    fn normalize_stdout_line(&mut self, line: &str) -> Vec<ServerEvent> {
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            return vec![ServerEvent::Error {
                error: ProtocolError {
                    code: ErrorCode::AppServerProtocolError,
                    message: "Failed to decode app-server JSON line".into(),
                    retryable: Some(false),
                    details: Some(json!({ "line": line })),
                },
            }];
        };

        if let Some(id) = value.get("id").and_then(Value::as_str) {
            if let Some(result) = value.get("result") {
                return vec![ServerEvent::AppServerResponse {
                    request_id: id.to_string(),
                    result: result.clone(),
                }];
            }

            if let Some(error) = value.get("error") {
                return vec![ServerEvent::Error {
                    error: ProtocolError {
                        code: ErrorCode::AppServerProtocolError,
                        message: "App-server returned an error response".into(),
                        retryable: Some(false),
                        details: Some(json!({
                            "request_id": id,
                            "error": error
                        })),
                    },
                }];
            }
        }

        let event_id = format!("app-server-event-{}", self.next_event_id);
        self.next_event_id += 1;
        vec![ServerEvent::AppServerEvent {
            event_id,
            payload: value,
        }]
    }

    fn current_host_status(&self) -> HostHealthStatus {
        if self.child.is_some() {
            if self.last_error.is_some() {
                HostHealthStatus::Degraded
            } else {
                HostHealthStatus::Ready
            }
        } else if self.last_error.is_some() || self.last_exit_code.is_some() {
            HostHealthStatus::Failed
        } else {
            HostHealthStatus::Starting
        }
    }

    fn current_app_server_state(&self) -> AppServerLifecycleState {
        if self.child.is_some() {
            if self.last_error.is_some() {
                AppServerLifecycleState::Degraded
            } else {
                AppServerLifecycleState::Ready
            }
        } else if self.last_error.is_some() || self.last_exit_code.is_some() {
            AppServerLifecycleState::Failed
        } else {
            AppServerLifecycleState::Stopped
        }
    }

    fn health_snapshot(
        &self,
        status: HostHealthStatus,
        app_server_state: AppServerLifecycleState,
    ) -> HostHealthSnapshot {
        HostHealthSnapshot {
            protocol_version: ENGINE_PROTOCOL_VERSION.into(),
            daemon_version: env!("CARGO_PKG_VERSION").into(),
            host_id: self.config.host_id.clone(),
            hostname: self.config.hostname.clone(),
            platform: self.config.platform.clone(),
            status,
            started_at: self.started_at.clone(),
            observed_at: self.observed_at.clone(),
            app_server: AppServerHealth {
                state: app_server_state,
                launch_command: launch_command_display(&self.config.spawn),
                cwd: self
                    .config
                    .spawn
                    .cwd
                    .as_ref()
                    .map(|path| path.display().to_string()),
                pid: self.child.as_ref().map(ManagedChild::pid),
                last_exit_code: self.last_exit_code,
                last_error: self.last_error.clone(),
                restart_count: self.restart_count,
            },
            capabilities: HostCapabilities {
                pairing: true,
                app_server_bridge: true,
                transcript_fallback: false,
                reconnect_resume: true,
            },
            paired_device_count: self.store.paired_devices.len() as u32,
        }
    }

    fn app_server_unavailable_error(&self, error: anyhow::Error) -> ServerEvent {
        ServerEvent::Error {
            error: ProtocolError {
                code: ErrorCode::AppServerUnavailable,
                message: "App-server bridge is unavailable".into(),
                retryable: Some(true),
                details: Some(json!({
                    "error": error.to_string()
                })),
            },
        }
    }

    fn authenticate_token(&self, bearer_token: &str) -> Option<String> {
        self.store
            .paired_devices
            .iter()
            .find(|record| record.token.bearer_token == bearer_token)
            .map(|record| record.device.device_id.clone())
    }

    fn is_authenticated(&self) -> bool {
        self.authenticated_device_id.is_some()
    }

    fn remove_device(&mut self, device_id: &str) -> bool {
        let initial_len = self.store.paired_devices.len();
        self.store
            .paired_devices
            .retain(|record| record.device.device_id != device_id);
        if self.authenticated_device_id.as_deref() == Some(device_id) {
            self.authenticated_device_id = None;
        }
        self.store.paired_devices.len() != initial_len
    }

    fn persist_store(&self) -> Result<()> {
        save_store(&self.config.state_dir, &self.store)
    }

    fn internal_error(&self, message: &str, error: anyhow::Error) -> ServerEvent {
        ServerEvent::Error {
            error: ProtocolError {
                code: ErrorCode::Internal,
                message: message.into(),
                retryable: Some(false),
                details: Some(json!({
                    "error": error.to_string()
                })),
            },
        }
    }
}

fn launch_command_display(config: &SpawnConfig) -> Vec<String> {
    let mut parts = vec![config.program.display().to_string()];
    parts.extend(config.args.clone());
    parts
}

fn now_string() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_secs();
    format!("{seconds}")
}

fn hostname_fallback() -> String {
    std::env::var("HOSTNAME").unwrap_or_else(|_| "localhost".into())
}

fn current_platform() -> HostPlatform {
    if cfg!(target_os = "macos") {
        HostPlatform::Macos
    } else {
        HostPlatform::Linux
    }
}

fn default_state_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".codex-island/hostd")
}

fn store_path(state_dir: &Path) -> PathBuf {
    state_dir.join("paired-devices.json")
}

fn load_store(state_dir: &Path) -> Result<HostStore> {
    let path = store_path(state_dir);
    if !path.exists() {
        return Ok(HostStore::default());
    }
    let content = std::fs::read_to_string(&path)
        .with_context(|| format!("read host store: {}", path.display()))?;
    serde_json::from_str(&content).with_context(|| format!("decode host store: {}", path.display()))
}

fn save_store(state_dir: &Path, store: &HostStore) -> Result<()> {
    std::fs::create_dir_all(state_dir)
        .with_context(|| format!("create host state dir: {}", state_dir.display()))?;
    let path = store_path(state_dir);
    let content = serde_json::to_string_pretty(store).context("serialize host store")?;
    std::fs::write(&path, content).with_context(|| format!("write host store: {}", path.display()))
}

fn generate_session_id(prefix: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_nanos();
    format!("{prefix}-{nanos}")
}

fn generate_pairing_code() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .subsec_nanos();
    format!("{:03}-{:03}", (nanos / 1000) % 1000, nanos % 1000)
}

#[derive(Debug, Clone)]
pub struct HostDaemonServerConfig {
    pub bind_addr: SocketAddr,
    pub daemon: HostDaemonConfig,
    pub poll_interval: Duration,
}

impl HostDaemonServerConfig {
    pub fn local(bind_addr: SocketAddr, shell: &Path) -> Self {
        Self {
            bind_addr,
            daemon: HostDaemonConfig::local(shell),
            poll_interval: Duration::from_millis(200),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum IncomingShellFrame {
    Command(ClientCommand),
    Envelope(codex_island_proto::ProtocolEnvelope<ClientCommand>),
}

pub fn serve_host_daemon(config: HostDaemonServerConfig) -> Result<()> {
    let listener = TcpListener::bind(config.bind_addr)
        .with_context(|| format!("bind hostd websocket listener: {}", config.bind_addr))?;

    for stream in listener.incoming() {
        let stream = stream.context("accept hostd client stream")?;
        let daemon_config = config.daemon.clone();
        let poll_interval = config.poll_interval;
        if let Err(error) = handle_host_daemon_client(stream, daemon_config, poll_interval) {
            eprintln!("codex-island-hostd: dropping client after session error: {error:#}");
        }
    }

    Ok(())
}

fn handle_host_daemon_client(
    stream: TcpStream,
    daemon_config: HostDaemonConfig,
    poll_interval: Duration,
) -> Result<()> {
    stream
        .set_read_timeout(Some(poll_interval))
        .context("set hostd websocket read timeout")?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .context("set hostd websocket write timeout")?;

    let mut socket = accept(stream).context("accept websocket handshake")?;
    let mut daemon = HostDaemon::new(daemon_config);
    send_server_events(&mut socket, daemon.start(), None)?;

    loop {
        match socket.read() {
            Ok(message) => {
                if !handle_ws_message(&mut socket, &mut daemon, message)? {
                    break;
                }
            }
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(tungstenite::Error::ConnectionClosed) | Err(tungstenite::Error::AlreadyClosed) => {
                break;
            }
            Err(error) => return Err(error).context("read hostd websocket frame"),
        }

        let poll_events = daemon.poll();
        if !poll_events.is_empty() {
            send_server_events(&mut socket, poll_events, None)?;
        }
    }

    daemon.stop().context("stop host daemon after websocket closes")?;
    Ok(())
}

fn handle_ws_message(
    socket: &mut WebSocket<TcpStream>,
    daemon: &mut HostDaemon,
    message: Message,
) -> Result<bool> {
    match message {
        Message::Text(text) => {
            let incoming: IncomingShellFrame =
                serde_json::from_str(&text).context("decode hostd shell frame")?;
            let (reply_id, command) = match incoming {
                IncomingShellFrame::Command(command) => (None, command),
                IncomingShellFrame::Envelope(envelope) => (Some(envelope.id), envelope.payload),
            };
            let events = daemon.handle_command(command);
            send_server_events(socket, events, reply_id.as_deref())?;
            Ok(true)
        }
        Message::Binary(_) => Ok(true),
        Message::Ping(payload) => {
            socket.send(Message::Pong(payload)).context("send websocket pong")?;
            Ok(true)
        }
        Message::Pong(_) => Ok(true),
        Message::Close(_) => {
            socket.close(None).ok();
            Ok(false)
        }
        Message::Frame(_) => Ok(true),
    }
}

fn send_server_events(
    socket: &mut WebSocket<TcpStream>,
    events: Vec<ServerEvent>,
    reply_id: Option<&str>,
) -> Result<()> {
    for event in events {
        let payload = if let Some(id) = reply_id {
            serde_json::to_string(&codex_island_proto::ProtocolEnvelope {
                id: id.to_string(),
                payload: event,
            })
        } else {
            serde_json::to_string(&event)
        }
        .context("serialize hostd server event")?;

        socket
            .send(Message::Text(payload))
            .context("send hostd websocket frame")?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::codex_app_server_command_with_cwd;
    use std::fs;
    use std::net::TcpListener;
    use std::path::{Path, PathBuf};
    use std::thread;
    use std::time::SystemTime;
    use std::time::{Duration, Instant};

    use codex_island_proto::{
        ClientCommand, ErrorCode, HostHealthStatus, ProtocolEnvelope, ServerEvent,
    };
    use serde_json::json;
    use tungstenite::{Message, connect};

    use super::{
        ChildEvent, HostDaemon, HostDaemonConfig, HostPlatform, ManagedChild, SpawnConfig,
        codex_app_server_command, handle_host_daemon_client,
    };

    struct FakeAppServerHarness {
        hostd: HostDaemon,
    }

    impl FakeAppServerHarness {
        fn new(script: &str) -> Self {
            let temp = unique_temp_dir("hostd-harness");
            let hostd = HostDaemon::new(HostDaemonConfig {
                host_id: "host-harness".into(),
                hostname: "devbox".into(),
                platform: HostPlatform::Macos,
                spawn: SpawnConfig::new("/bin/sh").args(["-c", script]),
                state_dir: temp.join("state"),
            });
            Self::from_hostd(hostd)
        }

        fn with_spawn(spawn: SpawnConfig) -> Self {
            let temp = unique_temp_dir("hostd-real-app-server");
            let hostd = HostDaemon::new(HostDaemonConfig {
                host_id: "host-real".into(),
                hostname: "devbox".into(),
                platform: current_test_platform(),
                spawn,
                state_dir: temp.join("state"),
            });
            Self::from_hostd(hostd)
        }

        fn from_hostd(mut hostd: HostDaemon) -> Self {
            hostd.start();

            let pairing_code = match &hostd.handle_command(ClientCommand::PairStart {
                device_name: "Harness Device".into(),
                client_platform: "android".into(),
            })[0]
            {
                ServerEvent::PairingStarted { pairing } => pairing.pairing_code.clone(),
                other => panic!("unexpected pair start: {other:?}"),
            };
            let token = match &hostd.handle_command(ClientCommand::PairConfirm {
                pairing_code,
                device_name: "Harness Device".into(),
                client_platform: "android".into(),
            })[0]
            {
                ServerEvent::PairingCompleted { token, .. } => token.bearer_token.clone(),
                other => panic!("unexpected pair complete: {other:?}"),
            };
            let hello = hostd.handle_command(ClientCommand::Hello {
                protocol_version: "v1".into(),
                client_name: "shell".into(),
                client_version: "0.1.0".into(),
                auth_token: Some(token),
            });
            assert!(matches!(
                &hello[0],
                ServerEvent::HelloAck { authenticated, .. } if *authenticated
            ));

            Self { hostd }
        }

        fn send_request(&mut self, request_id: &str, method: &str, params: serde_json::Value) {
            let events = self.hostd.handle_command(ClientCommand::AppServerRequest {
                request_id: request_id.into(),
                method: method.into(),
                params,
            });
            assert!(events.is_empty(), "unexpected request events: {events:?}");
        }

        fn send_notification(&mut self, method: &str, params: serde_json::Value) {
            self.hostd
                .send_to_app_server(json!({
                    "method": method,
                    "params": params,
                }))
                .expect("forward app-server notification");
        }

        fn interrupt(&mut self, thread_id: &str, turn_id: &str) {
            let events = self
                .hostd
                .handle_command(ClientCommand::AppServerInterrupt {
                    thread_id: thread_id.into(),
                    turn_id: turn_id.into(),
                });
            assert!(events.is_empty(), "unexpected interrupt events: {events:?}");
        }

        fn poll_until<F>(&mut self, timeout: Duration, predicate: F) -> Vec<ServerEvent>
        where
            F: Fn(&[ServerEvent]) -> bool,
        {
            wait_for_poll_events_until(&mut self.hostd, timeout, predicate)
        }
    }

    #[test]
    fn codex_command_uses_login_shell_stdio_contract() {
        let config = codex_app_server_command(Path::new("/bin/zsh"));
        assert_eq!(config.program, PathBuf::from("/bin/zsh"));
        assert_eq!(
            config.args,
            vec![
                "-lc".to_string(),
                "exec codex app-server --listen stdio://".to_string()
            ]
        );
        assert_eq!(config.cwd, None);
    }

    #[test]
    fn codex_command_propagates_cwd_into_launch_contract() {
        let config = codex_app_server_command_with_cwd(Path::new("/bin/zsh"), Some(Path::new("/tmp/repo root")));
        assert_eq!(config.program, PathBuf::from("/bin/zsh"));
        assert_eq!(
            config.args,
            vec![
                "-lc".to_string(),
                "exec codex --cd '/tmp/repo root' app-server --listen stdio://".to_string()
            ]
        );
        assert_eq!(config.cwd, Some(PathBuf::from("/tmp/repo root")));
    }

    #[test]
    fn flushes_stdout_and_stderr_without_trailing_newline() {
        let mut child = ManagedChild::spawn(&SpawnConfig::new("/bin/sh").args([
            "-c",
            "printf 'stdout-no-newline'; printf 'stderr-no-newline' >&2",
        ]))
        .expect("spawn child");

        let status = child.wait().expect("wait for child");
        assert!(status.success);

        let events = collect_events(&child, Duration::from_millis(200));
        assert!(events.contains(&ChildEvent::StdoutLine("stdout-no-newline".to_string())));
        assert!(events.contains(&ChildEvent::StderrLine("stderr-no-newline".to_string())));
    }

    #[test]
    fn propagates_cwd_to_child_process() {
        let cwd = unique_temp_dir("hostd-cwd");
        let mut child = ManagedChild::spawn(
            &SpawnConfig::new("/bin/pwd")
                .args(std::iter::empty::<&str>())
                .cwd(&cwd),
        )
        .expect("spawn pwd");

        let status = child.wait().expect("wait for pwd");
        assert!(status.success);

        let events = collect_events(&child, Duration::from_millis(200));
        let actual = events
            .iter()
            .find_map(|event| match event {
                ChildEvent::StdoutLine(line) => Some(PathBuf::from(line)),
                _ => None,
            })
            .expect("pwd output");
        assert_eq!(
            fs::canonicalize(actual).expect("canonicalize actual cwd"),
            fs::canonicalize(&cwd).expect("canonicalize expected cwd")
        );
    }

    #[test]
    fn surfaces_non_zero_exit_code_for_failed_child() {
        let mut child = ManagedChild::spawn(
            &SpawnConfig::new("/bin/sh").args(["-c", "echo boom >&2; exit 17"]),
        )
        .expect("spawn failing child");

        let status = child.wait().expect("wait for failing child");
        assert_eq!(status.code, Some(17));
        assert!(!status.success);

        let events = collect_events(&child, Duration::from_millis(200));
        assert!(events.contains(&ChildEvent::StderrLine("boom".to_string())));
    }

    #[test]
    fn stop_terminates_long_running_child_and_closes_stdin() {
        let mut child = ManagedChild::spawn(
            &SpawnConfig::new("/bin/sh").args(["-c", "trap '' TERM; cat >/dev/null & wait"]),
        )
        .expect("spawn long-running child");

        child.send_line("hello").expect("write stdin");
        let status = child.stop().expect("stop child");
        assert!(!status.success);
    }

    #[test]
    fn hostd_emits_hello_ack_and_snapshot() {
        let temp = unique_temp_dir("hostd-hello");
        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-1".into(),
            hostname: "devbox".into(),
            platform: HostPlatform::Macos,
            spawn: SpawnConfig::new("/bin/sh")
                .args(["-c", "sleep 1"])
                .cwd(&temp),
            state_dir: temp.join("state"),
        });

        let startup = hostd.start();
        assert!(matches!(
            &startup[0],
            ServerEvent::HostHealthChanged { health } if health.status == HostHealthStatus::Ready
        ));

        let hello = hostd.handle_command(ClientCommand::Hello {
            protocol_version: "v1".into(),
            client_name: "shell".into(),
            client_version: "0.1.0".into(),
            auth_token: None,
        });
        assert!(matches!(hello[0], ServerEvent::HelloAck { .. }));

        let snapshot = hostd.handle_command(ClientCommand::GetSnapshot);
        match &snapshot[0] {
            ServerEvent::Snapshot { snapshot } => {
                assert_eq!(snapshot.health.host_id, "host-1");
                assert_eq!(
                    snapshot.health.app_server.cwd.as_deref(),
                    Some(temp.to_string_lossy().as_ref())
                );
            }
            other => panic!("unexpected snapshot event: {other:?}"),
        }
    }

    #[test]
    fn hostd_normalizes_app_server_stdout_into_protocol_events() {
        let script = "while IFS= read -r line; do \
            printf '{\"id\":\"req-1\",\"result\":{\"ok\":true}}\\n'; \
            printf '{\"method\":\"thread/started\",\"params\":{\"threadId\":\"thread-1\"}}\\n'; \
            break; \
        done";
        let state_dir = unique_temp_dir("hostd-normalize-state");
        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-2".into(),
            hostname: "linux-box".into(),
            platform: HostPlatform::Linux,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", script]),
            state_dir,
        });

        hostd.start();
        let pairing_code = match &hostd.handle_command(ClientCommand::PairStart {
            device_name: "Pixel".into(),
            client_platform: "android".into(),
        })[0]
        {
            ServerEvent::PairingStarted { pairing } => pairing.pairing_code.clone(),
            other => panic!("unexpected pair start: {other:?}"),
        };
        let token = match &hostd.handle_command(ClientCommand::PairConfirm {
            pairing_code,
            device_name: "Pixel".into(),
            client_platform: "android".into(),
        })[0]
        {
            ServerEvent::PairingCompleted { token, .. } => token.bearer_token.clone(),
            other => panic!("unexpected pair complete: {other:?}"),
        };
        let _ = hostd.handle_command(ClientCommand::Hello {
            protocol_version: "v1".into(),
            client_name: "shell".into(),
            client_version: "0.1.0".into(),
            auth_token: Some(token),
        });
        let command_events = hostd.handle_command(ClientCommand::AppServerRequest {
            request_id: "req-1".into(),
            method: "thread/start".into(),
            params: json!({"cwd": "/repo"}),
        });
        assert!(command_events.is_empty());

        let events = wait_for_poll_events(&mut hostd, 2, Duration::from_secs(2));
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerResponse { request_id, result }
            if request_id == "req-1" && result["ok"] == json!(true)
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerEvent { payload, .. }
            if payload["method"] == json!("thread/started")
        )));
    }

    #[test]
    fn hostd_restarts_after_upstream_exit_and_updates_health() {
        let temp = unique_temp_dir("hostd-restart");
        let counter = temp.join("counter");
        let script = format!(
            "count=0; \
             if [ -f \"{0}\" ]; then count=$(cat \"{0}\"); fi; \
             count=$((count+1)); \
             printf '%s' \"$count\" > \"{0}\"; \
             if [ \"$count\" -eq 1 ]; then \
               echo 'boom' >&2; \
               exit 17; \
             fi; \
             printf '{{\"method\":\"host/recovered\",\"params\":{{\"attempt\":2}}}}\\n'; \
             sleep 1",
            counter.display()
        );
        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-3".into(),
            hostname: "linux-box".into(),
            platform: HostPlatform::Linux,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", &script]),
            state_dir: temp.join("state"),
        });

        hostd.start();

        let events = wait_for_poll_events_until(&mut hostd, Duration::from_secs(3), |events| {
            events.iter().any(|event| {
                matches!(
                    event,
                    ServerEvent::AppServerEvent { payload, .. }
                    if payload["method"] == json!("host/recovered")
                )
            })
        });
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::HostHealthChanged { health }
            if health.status == HostHealthStatus::Failed && health.app_server.last_exit_code == Some(17)
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::HostHealthChanged { health }
            if health.status == HostHealthStatus::Ready && health.app_server.restart_count == 1
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerEvent { payload, .. }
            if payload["method"] == json!("host/recovered")
        )));

        let snapshot = hostd.snapshot();
        assert_eq!(snapshot.health.app_server.restart_count, 1);
        assert_eq!(snapshot.health.app_server.last_exit_code, Some(17));
        assert_eq!(
            snapshot.health.app_server.last_error.as_deref(),
            Some("boom")
        );
    }

    #[test]
    fn websocket_server_accepts_hello_and_snapshot_commands() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral listener");
        let bind_addr = listener.local_addr().expect("local addr");
        let state_dir = unique_temp_dir("hostd-ws-state");
        let server_thread = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept test stream");
            handle_host_daemon_client(
                stream,
                HostDaemonConfig {
                    host_id: "host-ws".into(),
                    hostname: "devbox".into(),
                    platform: HostPlatform::Macos,
                    spawn: SpawnConfig::new("/bin/sh").args(["-c", "sleep 2"]),
                    state_dir,
                },
                Duration::from_millis(50),
            )
            .expect("run websocket server");
        });

        let url = format!("ws://{bind_addr}");
        let (mut socket, _) = connect(url.as_str()).expect("connect websocket");

        let startup = socket.read().expect("startup frame");
        let startup_text = startup.into_text().expect("startup text");
        let startup_event: ServerEvent =
            serde_json::from_str(&startup_text).expect("decode startup event");
        assert!(matches!(startup_event, ServerEvent::HostHealthChanged { .. }));

        let hello = ProtocolEnvelope {
            id: "msg-1".to_string(),
            payload: ClientCommand::Hello {
                protocol_version: "v1".into(),
                client_name: "android-shell".into(),
                client_version: "0.1.0".into(),
                auth_token: None,
            },
        };
        socket
            .send(Message::Text(
                serde_json::to_string(&hello).expect("encode hello"),
            ))
            .expect("send hello");
        let hello_reply = socket.read().expect("read hello reply");
        let hello_text = hello_reply.into_text().expect("hello text");
        let hello_event: ProtocolEnvelope<ServerEvent> =
            serde_json::from_str(&hello_text).expect("decode hello envelope");
        assert_eq!(hello_event.id, "msg-1");
        assert!(matches!(hello_event.payload, ServerEvent::HelloAck { .. }));

        let snapshot = ProtocolEnvelope {
            id: "msg-2".to_string(),
            payload: ClientCommand::GetSnapshot,
        };
        socket
            .send(Message::Text(
                serde_json::to_string(&snapshot).expect("encode snapshot request"),
            ))
            .expect("send snapshot");
        let snapshot_reply = socket.read().expect("read snapshot reply");
        let snapshot_text = snapshot_reply.into_text().expect("snapshot text");
        let snapshot_event: ProtocolEnvelope<ServerEvent> =
            serde_json::from_str(&snapshot_text).expect("decode snapshot envelope");
        assert_eq!(snapshot_event.id, "msg-2");
        assert!(matches!(snapshot_event.payload, ServerEvent::Snapshot { .. }));

        socket.close(None).expect("close websocket");
        server_thread.join().expect("join websocket server");
    }

    #[test]
    fn harness_covers_thread_list_send_and_interrupt_flow() {
        let script = "while IFS= read -r line; do \
            case \"$line\" in \
              *'\"method\":\"thread/list\"'*) \
                printf '{\"id\":\"req-list\",\"result\":{\"threads\":[{\"id\":\"thread-1\",\"title\":\"Inbox\"}]}}\\n' ;; \
              *'\"method\":\"turn/start\"'*) \
                printf '{\"id\":\"req-send\",\"result\":{\"accepted\":true}}\\n'; \
                printf '{\"method\":\"turn/started\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}\\n' ;; \
              *'\"method\":\"turn/interrupt\"'*) \
                printf '{\"id\":\"interrupt-thread-1-turn-1\",\"result\":{\"ok\":true}}\\n'; \
                printf '{\"method\":\"turn/interrupted\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}\\n'; \
                break ;; \
            esac; \
        done";
        let mut harness = FakeAppServerHarness::new(script);

        harness.send_request("req-list", "thread/list", json!({"limit": 100}));
        harness.send_request(
            "req-send",
            "turn/start",
            json!({"threadId": "thread-1", "input": [{"type": "text", "text": "hello"}]}),
        );
        harness.interrupt("thread-1", "turn-1");

        let events = harness.poll_until(Duration::from_secs(2), |events| {
            events.iter().any(|event| {
                matches!(
                    event,
                    ServerEvent::AppServerEvent { payload, .. }
                    if payload["method"] == json!("turn/interrupted")
                )
            })
        });

        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerResponse { request_id, result }
            if request_id == "req-list" && result["threads"][0]["id"] == json!("thread-1")
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerResponse { request_id, result }
            if request_id == "req-send" && result["accepted"] == json!(true)
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerEvent { payload, .. }
            if payload["method"] == json!("turn/started")
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerEvent { payload, .. }
            if payload["method"] == json!("turn/interrupted")
        )));
    }

    #[test]
    fn harness_covers_approval_and_request_user_input_events() {
        let script = "while IFS= read -r line; do \
            case \"$line\" in \
              *'\"method\":\"turn/start\"'*) \
                printf '{\"id\":\"req-approval\",\"result\":{\"accepted\":true}}\\n'; \
                printf '{\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"command\":\"git push\"}}\\n'; \
                printf '{\"method\":\"item/tool/requestUserInput\",\"params\":{\"threadId\":\"thread-1\",\"question\":\"choose\"}}\\n'; \
                break ;; \
            esac; \
        done";
        let mut harness = FakeAppServerHarness::new(script);

        harness.send_request(
            "req-approval",
            "turn/start",
            json!({"threadId": "thread-1", "input": [{"type": "text", "text": "deploy"}]}),
        );

        let events = harness.poll_until(Duration::from_secs(2), |events| {
            let saw_approval = events.iter().any(|event| {
                matches!(
                    event,
                    ServerEvent::AppServerEvent { payload, .. }
                    if payload["method"] == json!("item/commandExecution/requestApproval")
                )
            });
            let saw_input = events.iter().any(|event| {
                matches!(
                    event,
                    ServerEvent::AppServerEvent { payload, .. }
                    if payload["method"] == json!("item/tool/requestUserInput")
                )
            });
            saw_approval && saw_input
        });

        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerEvent { payload, .. }
            if payload["method"] == json!("item/commandExecution/requestApproval")
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerEvent { payload, .. }
            if payload["method"] == json!("item/tool/requestUserInput")
        )));
    }

    #[test]
    fn harness_forwards_app_server_responses_without_blocking_follow_up_requests() {
        let script = "while IFS= read -r line; do \
            case \"$line\" in \
              *'\"result\":{\"decision\":\"accept\"}'*) \
                printf '{\"method\":\"serverRequest/resolved\",\"params\":{\"threadId\":\"thread-1\",\"requestId\":\"approval-1\"}}\\n' ;; \
              *'\"method\":\"thread/list\"'*) \
                printf '{\"id\":\"req-list\",\"result\":{\"threads\":[{\"id\":\"thread-1\",\"title\":\"Inbox\"}]}}\\n'; \
                break ;; \
            esac; \
        done";
        let mut harness = FakeAppServerHarness::new(script);

        let events = harness.hostd.handle_command(ClientCommand::AppServerResponse {
            request_id: "approval-1".into(),
            result: json!({ "decision": "accept" }),
        });
        assert!(events.is_empty(), "unexpected response forwarding events: {events:?}");

        harness.send_request("req-list", "thread/list", json!({"limit": 100}));

        let events = harness.poll_until(Duration::from_secs(2), |events| {
            let resolved = events.iter().any(|event| {
                matches!(
                    event,
                    ServerEvent::AppServerEvent { payload, .. }
                    if payload["method"] == json!("serverRequest/resolved")
                )
            });
            let listed = events.iter().any(|event| {
                matches!(
                    event,
                    ServerEvent::AppServerResponse { request_id, .. }
                    if request_id == "req-list"
                )
            });
            resolved && listed
        });

        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerEvent { payload, .. }
            if payload["method"] == json!("serverRequest/resolved")
        )));
        assert!(events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerResponse { request_id, result }
            if request_id == "req-list" && result["threads"][0]["id"] == json!("thread-1")
        )));
    }

    #[test]
    fn hostd_runs_real_codex_app_server_handshake_when_available() {
        let Some(codex_path) = find_codex_binary() else {
            eprintln!("skipping real codex app-server handshake test: codex not found on PATH");
            return;
        };
        let mut harness = FakeAppServerHarness::with_spawn(
            SpawnConfig::new(codex_path).args(["app-server", "--listen", "stdio://"]),
        );

        harness.send_request(
            "req-init",
            "initialize",
            json!({
                "capabilities": {
                    "experimentalApi": true
                },
                "clientInfo": {
                    "name": "codex_island",
                    "title": "Codex Island",
                    "version": "0.1.0"
                }
            }),
        );

        let init_events = harness.poll_until(Duration::from_secs(10), |events| {
            events.iter().any(|event| {
                matches!(
                    event,
                    ServerEvent::AppServerResponse { request_id, result }
                    if request_id == "req-init" && result.get("codexHome").is_some()
                )
            })
        });
        assert!(init_events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerResponse { request_id, result }
            if request_id == "req-init"
                && result.get("userAgent").and_then(|value| value.as_str()).is_some()
                && result["platformFamily"] == json!("unix")
                && result["platformOs"] == json!(expected_platform_os())
        )));

        harness.send_notification("initialized", serde_json::Value::Null);
        harness.send_request("req-list", "thread/list", json!({ "limit": 1 }));

        let list_events = harness.poll_until(Duration::from_secs(10), |events| {
            events.iter().any(|event| {
                matches!(
                    event,
                    ServerEvent::AppServerResponse { request_id, result }
                    if request_id == "req-list" && result.get("data").is_some()
                )
            })
        });
        assert!(list_events.iter().any(|event| matches!(
            event,
            ServerEvent::AppServerResponse { request_id, result }
            if request_id == "req-list" && result.get("data").is_some()
        )));
    }

    #[test]
    fn hostd_rejects_wrong_protocol_version() {
        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-4".into(),
            hostname: "devbox".into(),
            platform: HostPlatform::Macos,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", "sleep 1"]),
            state_dir: unique_temp_dir("hostd-invalid-auth"),
        });

        let events = hostd.handle_command(ClientCommand::Hello {
            protocol_version: "v2".into(),
            client_name: "shell".into(),
            client_version: "0.1.0".into(),
            auth_token: None,
        });
        assert!(matches!(
            &events[0],
            ServerEvent::Error { error }
            if error.code == ErrorCode::InvalidProtocolVersion
        ));
    }

    #[test]
    fn pairing_persists_device_and_allows_authenticated_hello() {
        let temp = unique_temp_dir("hostd-pair");
        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-5".into(),
            hostname: "devbox".into(),
            platform: HostPlatform::Macos,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", "sleep 1"]),
            state_dir: temp.join("state"),
        });

        let started = hostd.handle_command(ClientCommand::PairStart {
            device_name: "Pixel".into(),
            client_platform: "android".into(),
        });
        let pairing_code = match &started[0] {
            ServerEvent::PairingStarted { pairing } => pairing.pairing_code.clone(),
            other => panic!("unexpected pairing start: {other:?}"),
        };

        let completed = hostd.handle_command(ClientCommand::PairConfirm {
            pairing_code,
            device_name: "Pixel".into(),
            client_platform: "android".into(),
        });
        let token = match &completed[0] {
            ServerEvent::PairingCompleted { token, device, .. } => {
                assert_eq!(device.device_name, "Pixel");
                token.bearer_token.clone()
            }
            other => panic!("unexpected pairing complete: {other:?}"),
        };

        let snapshot = hostd.snapshot();
        assert_eq!(snapshot.health.paired_device_count, 1);
        assert_eq!(snapshot.paired_devices.len(), 1);

        let hello = hostd.handle_command(ClientCommand::Hello {
            protocol_version: "v1".into(),
            client_name: "shell".into(),
            client_version: "0.1.0".into(),
            auth_token: Some(token),
        });
        assert!(matches!(
            &hello[0],
            ServerEvent::HelloAck { authenticated, .. } if *authenticated
        ));

        let persisted = std::fs::read_to_string(temp.join("state/paired-devices.json"))
            .expect("read persisted store");
        assert!(persisted.contains("Pixel"));
    }

    #[test]
    fn app_server_bridge_requires_pairing_authentication() {
        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-6".into(),
            hostname: "linux-box".into(),
            platform: HostPlatform::Linux,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", "sleep 1"]),
            state_dir: unique_temp_dir("hostd-auth-required"),
        });

        let events = hostd.handle_command(ClientCommand::AppServerRequest {
            request_id: "req-1".into(),
            method: "thread/start".into(),
            params: json!({}),
        });
        assert!(matches!(
            &events[0],
            ServerEvent::Error { error } if error.code == ErrorCode::PairingRequired
        ));
    }

    #[test]
    fn revoke_removes_persisted_device_and_invalidates_token() {
        let temp = unique_temp_dir("hostd-revoke");
        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-7".into(),
            hostname: "devbox".into(),
            platform: HostPlatform::Macos,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", "sleep 1"]),
            state_dir: temp.join("state"),
        });

        let pairing_code = match &hostd.handle_command(ClientCommand::PairStart {
            device_name: "iPhone".into(),
            client_platform: "ios".into(),
        })[0]
        {
            ServerEvent::PairingStarted { pairing } => pairing.pairing_code.clone(),
            other => panic!("unexpected pair start: {other:?}"),
        };

        let (device_id, token) = match &hostd.handle_command(ClientCommand::PairConfirm {
            pairing_code,
            device_name: "iPhone".into(),
            client_platform: "ios".into(),
        })[0]
        {
            ServerEvent::PairingCompleted { device, token, .. } => {
                (device.device_id.clone(), token.bearer_token.clone())
            }
            other => panic!("unexpected pair complete: {other:?}"),
        };

        let _ = hostd.handle_command(ClientCommand::Hello {
            protocol_version: "v1".into(),
            client_name: "shell".into(),
            client_version: "0.1.0".into(),
            auth_token: Some(token.clone()),
        });
        let revoked = hostd.handle_command(ClientCommand::PairRevoke {
            device_id: device_id.clone(),
        });
        assert!(matches!(
            &revoked[0],
            ServerEvent::PairingRevoked { device_id: revoked_id } if revoked_id == &device_id
        ));

        let hello = hostd.handle_command(ClientCommand::Hello {
            protocol_version: "v1".into(),
            client_name: "shell".into(),
            client_version: "0.1.0".into(),
            auth_token: Some(token),
        });
        assert!(matches!(
            &hello[0],
            ServerEvent::Error { error } if error.code == ErrorCode::Unauthorized
        ));
    }

    #[test]
    fn store_is_loaded_on_restart() {
        let temp = unique_temp_dir("hostd-store-reload");
        let state_dir = temp.join("state");

        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-8".into(),
            hostname: "devbox".into(),
            platform: HostPlatform::Macos,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", "sleep 1"]),
            state_dir: state_dir.clone(),
        });
        let pairing_code = match &hostd.handle_command(ClientCommand::PairStart {
            device_name: "Tablet".into(),
            client_platform: "android".into(),
        })[0]
        {
            ServerEvent::PairingStarted { pairing } => pairing.pairing_code.clone(),
            other => panic!("unexpected pair start: {other:?}"),
        };
        let token = match &hostd.handle_command(ClientCommand::PairConfirm {
            pairing_code,
            device_name: "Tablet".into(),
            client_platform: "android".into(),
        })[0]
        {
            ServerEvent::PairingCompleted { token, .. } => token.bearer_token.clone(),
            other => panic!("unexpected pair complete: {other:?}"),
        };
        drop(hostd);

        let mut reloaded = HostDaemon::new(HostDaemonConfig {
            host_id: "host-8".into(),
            hostname: "devbox".into(),
            platform: HostPlatform::Macos,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", "sleep 1"]),
            state_dir,
        });
        assert_eq!(reloaded.snapshot().paired_devices.len(), 1);
        let hello = reloaded.handle_command(ClientCommand::Hello {
            protocol_version: "v1".into(),
            client_name: "shell".into(),
            client_version: "0.1.0".into(),
            auth_token: Some(token),
        });
        assert!(matches!(
            &hello[0],
            ServerEvent::HelloAck { authenticated, .. } if *authenticated
        ));
    }

    fn collect_events(child: &ManagedChild, timeout: Duration) -> Vec<ChildEvent> {
        let deadline = Instant::now() + timeout;
        let mut events = Vec::new();

        loop {
            match child.try_recv_event() {
                Ok(event) => events.push(event),
                Err(std::sync::mpsc::TryRecvError::Empty) if Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(10));
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => break,
            }
        }

        events
    }

    fn wait_for_poll_events(
        hostd: &mut HostDaemon,
        min_events: usize,
        timeout: Duration,
    ) -> Vec<ServerEvent> {
        let deadline = Instant::now() + timeout;
        let mut events = Vec::new();

        while Instant::now() < deadline {
            events.extend(hostd.poll());
            if events.len() >= min_events {
                return events;
            }
            thread::sleep(Duration::from_millis(20));
        }

        events
    }

    fn wait_for_poll_events_until<F>(
        hostd: &mut HostDaemon,
        timeout: Duration,
        predicate: F,
    ) -> Vec<ServerEvent>
    where
        F: Fn(&[ServerEvent]) -> bool,
    {
        let deadline = Instant::now() + timeout;
        let mut events = Vec::new();

        while Instant::now() < deadline {
            events.extend(hostd.poll());
            if predicate(&events) {
                return events;
            }
            thread::sleep(Duration::from_millis(20));
        }

        events
    }

    fn unique_temp_dir(prefix: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        let nanos = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("system time before epoch")
            .as_nanos();
        let unique = format!("{prefix}-{}-{}", std::process::id(), nanos);
        path.push(unique);
        fs::create_dir_all(&path).expect("create temp dir");
        path
    }

    fn find_codex_binary() -> Option<PathBuf> {
        std::env::var_os("PATH").and_then(|path| {
            std::env::split_paths(&path).find_map(|entry| {
                let candidate = entry.join("codex");
                if candidate.is_file() {
                    Some(candidate)
                } else {
                    None
                }
            })
        })
    }

    fn current_test_platform() -> HostPlatform {
        if cfg!(target_os = "macos") {
            HostPlatform::Macos
        } else {
            HostPlatform::Linux
        }
    }

    fn expected_platform_os() -> &'static str {
        if cfg!(target_os = "macos") {
            "macos"
        } else {
            "linux"
        }
    }
}
