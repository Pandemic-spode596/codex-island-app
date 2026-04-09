use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow};
use codex_island_proto::{
    AppServerHealth, AppServerLifecycleState, ClientCommand, ENGINE_PROTOCOL_VERSION,
    EngineSnapshot, ErrorCode, HostCapabilities, HostHealthSnapshot, HostHealthStatus,
    HostPlatform, ProtocolError, ServerEvent,
};
use serde_json::{Value, json};

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

pub fn codex_app_server_command(shell: &Path) -> SpawnConfig {
    SpawnConfig::new(shell).args(["-lc", "exec codex app-server --listen stdio://"])
}

#[derive(Debug, Clone)]
pub struct HostDaemonConfig {
    pub host_id: String,
    pub hostname: String,
    pub platform: HostPlatform,
    pub spawn: SpawnConfig,
}

impl HostDaemonConfig {
    pub fn local(shell: &Path) -> Self {
        Self {
            host_id: "local-host".into(),
            hostname: hostname_fallback(),
            platform: current_platform(),
            spawn: codex_app_server_command(shell),
        }
    }
}

pub struct HostDaemon {
    config: HostDaemonConfig,
    child: Option<ManagedChild>,
    started_at: String,
    observed_at: String,
    last_error: Option<String>,
    last_exit_code: Option<i32>,
    restart_count: u32,
    next_event_id: u64,
}

impl HostDaemon {
    pub fn new(config: HostDaemonConfig) -> Self {
        let now = now_string();
        Self {
            config,
            child: None,
            started_at: now.clone(),
            observed_at: now,
            last_error: None,
            last_exit_code: None,
            restart_count: 0,
            next_event_id: 1,
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
                protocol_version, ..
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

                vec![ServerEvent::HelloAck {
                    protocol_version: ENGINE_PROTOCOL_VERSION.into(),
                    daemon_version: env!("CARGO_PKG_VERSION").into(),
                    host_id: self.config.host_id.clone(),
                    authenticated: false,
                }]
            }
            ClientCommand::GetSnapshot => vec![ServerEvent::Snapshot {
                snapshot: self.snapshot(),
            }],
            ClientCommand::AppServerRequest {
                request_id,
                method,
                params,
            } => {
                if let Err(error) = self.send_to_app_server(json!({
                    "id": request_id,
                    "method": method,
                    "params": params
                })) {
                    return vec![self.app_server_unavailable_error(error)];
                }
                Vec::new()
            }
            ClientCommand::AppServerInterrupt { thread_id, turn_id } => {
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
            ClientCommand::PairStart { .. }
            | ClientCommand::PairConfirm { .. }
            | ClientCommand::PairRevoke { .. } => vec![ServerEvent::Error {
                error: ProtocolError {
                    code: ErrorCode::UnsupportedCommand,
                    message: "Pairing store is not implemented in island-hostd yet".into(),
                    retryable: Some(false),
                    details: None,
                },
            }],
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
            active_pairing: None,
            paired_devices: Vec::new(),
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
                pairing: false,
                app_server_bridge: true,
                transcript_fallback: false,
                reconnect_resume: true,
            },
            paired_device_count: 0,
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

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::thread;
    use std::time::SystemTime;
    use std::time::{Duration, Instant};

    use codex_island_proto::{ClientCommand, ErrorCode, HostHealthStatus, ServerEvent};
    use serde_json::json;

    use super::{
        ChildEvent, HostDaemon, HostDaemonConfig, HostPlatform, ManagedChild, SpawnConfig,
        codex_app_server_command,
    };

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
        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-2".into(),
            hostname: "linux-box".into(),
            platform: HostPlatform::Linux,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", script]),
        });

        hostd.start();
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
    fn hostd_rejects_wrong_protocol_version() {
        let mut hostd = HostDaemon::new(HostDaemonConfig {
            host_id: "host-4".into(),
            hostname: "devbox".into(),
            platform: HostPlatform::Macos,
            spawn: SpawnConfig::new("/bin/sh").args(["-c", "sleep 1"]),
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
}
