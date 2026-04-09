use codex_island_proto::{
    AppServerHealth, AppServerLifecycleState, ClientCommand, EngineSnapshot, ErrorCode,
    HostCapabilities, HostHealthSnapshot, HostHealthStatus, HostPlatform, PairedDeviceRecord,
    ProtocolError, ServerEvent, current_version,
};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Error,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ClientRuntimeState {
    pub connection: ClientConnectionState,
    pub snapshot: EngineSnapshot,
    pub last_error: Option<ProtocolError>,
    pub last_app_server_event: Option<Value>,
    pub authenticated: bool,
    pub auth_token: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ClientRuntime {
    client_name: String,
    client_version: String,
    state: ClientRuntimeState,
}

impl ClientRuntime {
    pub fn new(
        client_name: impl Into<String>,
        client_version: impl Into<String>,
        auth_token: Option<String>,
    ) -> Self {
        Self {
            client_name: client_name.into(),
            client_version: client_version.into(),
            state: ClientRuntimeState {
                connection: ClientConnectionState::Disconnected,
                snapshot: default_snapshot(),
                last_error: None,
                last_app_server_event: None,
                authenticated: auth_token.is_some(),
                auth_token,
            },
        }
    }

    pub fn client_name(&self) -> &str {
        &self.client_name
    }

    pub fn client_version(&self) -> &str {
        &self.client_version
    }

    pub fn auth_token(&self) -> Option<&str> {
        self.state.auth_token.as_deref()
    }

    pub fn replace_auth_token(&mut self, auth_token: Option<String>) {
        self.state.auth_token = auth_token;
        self.state.authenticated = self.state.auth_token.is_some();
    }

    pub fn binding_surface_version(&self) -> String {
        let version = current_version();
        format!("codex-island-engine {} ({})", version.engine, version.protocol)
    }

    pub fn state(&self) -> &ClientRuntimeState {
        &self.state
    }

    pub fn state_mut(&mut self) -> &mut ClientRuntimeState {
        &mut self.state
    }

    pub fn hello_command(&mut self) -> ClientCommand {
        self.state.connection = ClientConnectionState::Connecting;
        ClientCommand::Hello {
            protocol_version: current_version().protocol.into(),
            client_name: self.client_name.clone(),
            client_version: self.client_version.clone(),
            auth_token: self.state.auth_token.clone(),
        }
    }

    pub fn get_snapshot_command(&self) -> ClientCommand {
        ClientCommand::GetSnapshot
    }

    pub fn pair_start_command(
        &self,
        device_name: impl Into<String>,
        client_platform: impl Into<String>,
    ) -> ClientCommand {
        ClientCommand::PairStart {
            device_name: device_name.into(),
            client_platform: client_platform.into(),
        }
    }

    pub fn pair_confirm_command(
        &self,
        pairing_code: impl Into<String>,
        device_name: impl Into<String>,
        client_platform: impl Into<String>,
    ) -> ClientCommand {
        ClientCommand::PairConfirm {
            pairing_code: pairing_code.into(),
            device_name: device_name.into(),
            client_platform: client_platform.into(),
        }
    }

    pub fn pair_revoke_command(&self, device_id: impl Into<String>) -> ClientCommand {
        ClientCommand::PairRevoke {
            device_id: device_id.into(),
        }
    }

    pub fn app_server_request_command(
        &self,
        request_id: impl Into<String>,
        method: impl Into<String>,
        params: Value,
    ) -> ClientCommand {
        ClientCommand::AppServerRequest {
            request_id: request_id.into(),
            method: method.into(),
            params,
        }
    }

    pub fn app_server_interrupt_command(
        &self,
        thread_id: impl Into<String>,
        turn_id: impl Into<String>,
    ) -> ClientCommand {
        ClientCommand::AppServerInterrupt {
            thread_id: thread_id.into(),
            turn_id: turn_id.into(),
        }
    }

    pub fn apply_server_event(&mut self, event: ServerEvent) -> &ClientRuntimeState {
        match event {
            ServerEvent::HelloAck {
                protocol_version,
                daemon_version,
                host_id,
                authenticated,
            } => {
                self.state.connection = ClientConnectionState::Connected;
                self.state.authenticated = authenticated;
                self.state.snapshot.health.protocol_version = protocol_version;
                self.state.snapshot.health.daemon_version = daemon_version;
                self.state.snapshot.health.host_id = host_id;
                self.state.last_error = None;
            }
            ServerEvent::Snapshot { snapshot } => {
                self.state.connection = ClientConnectionState::Connected;
                self.state.snapshot = snapshot;
                self.state.last_error = None;
            }
            ServerEvent::HostHealthChanged { health } => {
                self.state.connection = ClientConnectionState::Connected;
                self.state.snapshot.health = health;
            }
            ServerEvent::PairingStarted { pairing } => {
                self.state.snapshot.active_pairing = Some(pairing);
            }
            ServerEvent::PairingCompleted { device, token, .. } => {
                self.state.snapshot.active_pairing = None;
                upsert_device(&mut self.state.snapshot.paired_devices, device);
                self.state.auth_token = Some(token.bearer_token);
                self.state.authenticated = true;
                self.state.last_error = None;
            }
            ServerEvent::PairingRevoked { device_id } => {
                self.state
                    .snapshot
                    .paired_devices
                    .retain(|device| device.device_id != device_id);
            }
            ServerEvent::AppServerEvent { payload, .. } => {
                self.state.connection = ClientConnectionState::Connected;
                self.state.last_app_server_event = Some(payload);
            }
            ServerEvent::AppServerResponse { .. } => {
                self.state.connection = ClientConnectionState::Connected;
            }
            ServerEvent::Error { error } => {
                self.state.connection = classify_error(&error);
                self.state.last_error = Some(error);
            }
        }

        &self.state
    }
}

fn default_snapshot() -> EngineSnapshot {
    let version = current_version();
    EngineSnapshot {
        health: HostHealthSnapshot {
            protocol_version: version.protocol.into(),
            daemon_version: version.engine.into(),
            host_id: "unknown-host".into(),
            hostname: "unknown".into(),
            platform: HostPlatform::Macos,
            status: HostHealthStatus::Starting,
            started_at: String::new(),
            observed_at: String::new(),
            app_server: AppServerHealth {
                state: AppServerLifecycleState::Stopped,
                launch_command: Vec::new(),
                cwd: None,
                pid: None,
                last_exit_code: None,
                last_error: None,
                restart_count: 0,
            },
            capabilities: HostCapabilities {
                pairing: true,
                app_server_bridge: true,
                transcript_fallback: true,
                reconnect_resume: true,
            },
            paired_device_count: 0,
        },
        active_pairing: None,
        paired_devices: Vec::new(),
        active_thread_id: None,
        active_turn_id: None,
    }
}

fn upsert_device(devices: &mut Vec<PairedDeviceRecord>, next: PairedDeviceRecord) {
    match devices.iter_mut().find(|device| device.device_id == next.device_id) {
        Some(existing) => *existing = next,
        None => devices.push(next),
    }
}

fn classify_error(error: &ProtocolError) -> ClientConnectionState {
    match error.code {
        ErrorCode::InvalidProtocolVersion | ErrorCode::Internal => ClientConnectionState::Error,
        _ => ClientConnectionState::Disconnected,
    }
}

#[cfg(test)]
mod tests {
    use codex_island_proto::{
        AppServerHealth, AppServerLifecycleState, AuthToken, EngineSnapshot, HostCapabilities,
        HostHealthSnapshot, HostHealthStatus, HostPlatform, PairedDeviceRecord, PairingSession,
        PairingSessionStatus, ServerEvent, current_version,
    };
    use serde_json::json;

    use super::{ClientConnectionState, ClientRuntime};

    #[test]
    fn hello_command_carries_client_identity_and_token() {
        let mut runtime = ClientRuntime::new("codex-island-android", "0.1.0", Some("secret".into()));

        let command = runtime.hello_command();

        assert_eq!(runtime.state().connection, ClientConnectionState::Connecting);
        assert_eq!(
            serde_json::to_value(command).expect("serialize hello"),
            json!({
                "type": "hello",
                "protocol_version": current_version().protocol,
                "client_name": "codex-island-android",
                "client_version": "0.1.0",
                "auth_token": "secret"
            })
        );
    }

    #[test]
    fn apply_snapshot_replaces_runtime_snapshot() {
        let mut runtime = ClientRuntime::new("codex-island-swift", "0.1.0", None);
        let snapshot = sample_snapshot();

        runtime.apply_server_event(ServerEvent::Snapshot {
            snapshot: snapshot.clone(),
        });

        assert_eq!(runtime.state().connection, ClientConnectionState::Connected);
        assert_eq!(runtime.state().snapshot, snapshot);
    }

    #[test]
    fn pairing_completion_promotes_authentication_state() {
        let mut runtime = ClientRuntime::new("codex-island-swift", "0.1.0", None);
        let sample = sample_snapshot();

        runtime.apply_server_event(ServerEvent::PairingCompleted {
            pairing: sample.active_pairing.expect("pairing"),
            device: sample.paired_devices[0].clone(),
            token: AuthToken {
                token_id: "token-1".into(),
                bearer_token: "bearer-1".into(),
                expires_at: None,
            },
        });

        assert_eq!(runtime.state().auth_token.as_deref(), Some("bearer-1"));
        assert!(runtime.state().authenticated);
        assert_eq!(runtime.state().snapshot.paired_devices.len(), 1);
    }

    fn sample_snapshot() -> EngineSnapshot {
        EngineSnapshot {
            health: HostHealthSnapshot {
                protocol_version: "v1".into(),
                daemon_version: "0.1.0".into(),
                host_id: "host-1".into(),
                hostname: "devbox".into(),
                platform: HostPlatform::Macos,
                status: HostHealthStatus::Ready,
                started_at: "2026-04-09T00:00:00Z".into(),
                observed_at: "2026-04-09T00:01:00Z".into(),
                app_server: AppServerHealth {
                    state: AppServerLifecycleState::Ready,
                    launch_command: vec![
                        "/bin/zsh".into(),
                        "-lc".into(),
                        "exec codex app-server --listen stdio://".into(),
                    ],
                    cwd: Some("/repo".into()),
                    pid: Some(42),
                    last_exit_code: None,
                    last_error: None,
                    restart_count: 0,
                },
                capabilities: HostCapabilities {
                    pairing: true,
                    app_server_bridge: true,
                    transcript_fallback: true,
                    reconnect_resume: true,
                },
                paired_device_count: 1,
            },
            active_pairing: Some(PairingSession {
                pairing_code: "ABC-123".into(),
                session_id: "pair-1".into(),
                status: PairingSessionStatus::Pending,
                expires_at: "2026-04-09T00:05:00Z".into(),
                device_name: Some("Pixel".into()),
            }),
            paired_devices: vec![PairedDeviceRecord {
                device_id: "device-1".into(),
                device_name: "Pixel".into(),
                platform: "android".into(),
                created_at: "2026-04-09T00:00:00Z".into(),
                last_seen_at: Some("2026-04-09T00:01:00Z".into()),
                last_ip: Some("192.168.1.20".into()),
            }],
            active_thread_id: Some("thread-1".into()),
            active_turn_id: Some("turn-1".into()),
        }
    }
}
