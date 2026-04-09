use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const ENGINE_PROTOCOL_VERSION: &str = "v1";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EngineVersion {
    pub protocol: &'static str,
    pub engine: &'static str,
}

pub fn current_version() -> EngineVersion {
    EngineVersion {
        protocol: ENGINE_PROTOCOL_VERSION,
        engine: env!("CARGO_PKG_VERSION"),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProtocolEnvelope<T> {
    pub id: String,
    pub payload: T,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HostPlatform {
    Macos,
    Linux,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HostHealthStatus {
    Starting,
    Ready,
    Degraded,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AppServerLifecycleState {
    Stopped,
    Starting,
    Ready,
    Degraded,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppServerHealth {
    pub state: AppServerLifecycleState,
    pub launch_command: Vec<String>,
    pub cwd: Option<String>,
    pub pid: Option<u32>,
    pub last_exit_code: Option<i32>,
    pub last_error: Option<String>,
    pub restart_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HostCapabilities {
    pub pairing: bool,
    pub app_server_bridge: bool,
    pub transcript_fallback: bool,
    pub reconnect_resume: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HostHealthSnapshot {
    pub protocol_version: String,
    pub daemon_version: String,
    pub host_id: String,
    pub hostname: String,
    pub platform: HostPlatform,
    pub status: HostHealthStatus,
    pub started_at: String,
    pub observed_at: String,
    pub app_server: AppServerHealth,
    pub capabilities: HostCapabilities,
    pub paired_device_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PairingSessionStatus {
    Pending,
    Confirmed,
    Expired,
    Revoked,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingSession {
    pub pairing_code: String,
    pub session_id: String,
    pub status: PairingSessionStatus,
    pub expires_at: String,
    pub device_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairedDeviceRecord {
    pub device_id: String,
    pub device_name: String,
    pub platform: String,
    pub created_at: String,
    pub last_seen_at: Option<String>,
    pub last_ip: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuthToken {
    pub token_id: String,
    pub bearer_token: String,
    pub expires_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EngineSnapshot {
    pub health: HostHealthSnapshot,
    pub active_pairing: Option<PairingSession>,
    pub paired_devices: Vec<PairedDeviceRecord>,
    pub active_thread_id: Option<String>,
    pub active_turn_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientCommand {
    Hello {
        protocol_version: String,
        client_name: String,
        client_version: String,
        auth_token: Option<String>,
    },
    GetSnapshot,
    PairStart {
        device_name: String,
        client_platform: String,
    },
    PairConfirm {
        pairing_code: String,
        device_name: String,
        client_platform: String,
    },
    PairRevoke {
        device_id: String,
    },
    AppServerRequest {
        request_id: String,
        method: String,
        params: Value,
    },
    AppServerInterrupt {
        thread_id: String,
        turn_id: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerEvent {
    HelloAck {
        protocol_version: String,
        daemon_version: String,
        host_id: String,
        authenticated: bool,
    },
    Snapshot {
        snapshot: EngineSnapshot,
    },
    HostHealthChanged {
        health: HostHealthSnapshot,
    },
    PairingStarted {
        pairing: PairingSession,
    },
    PairingCompleted {
        pairing: PairingSession,
        device: PairedDeviceRecord,
        token: AuthToken,
    },
    PairingRevoked {
        device_id: String,
    },
    AppServerEvent {
        event_id: String,
        payload: Value,
    },
    AppServerResponse {
        request_id: String,
        result: Value,
    },
    Error {
        error: ProtocolError,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidProtocolVersion,
    Unauthorized,
    UnsupportedCommand,
    PairingRequired,
    PairingCodeExpired,
    DeviceNotFound,
    AppServerUnavailable,
    AppServerProtocolError,
    Internal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProtocolError {
    pub code: ErrorCode,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retryable: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::{
        AppServerHealth, AppServerLifecycleState, ClientCommand, EngineSnapshot, ErrorCode,
        HostCapabilities, HostHealthSnapshot, HostHealthStatus, HostPlatform, PairedDeviceRecord,
        PairingSession, PairingSessionStatus, ProtocolEnvelope, ProtocolError, ServerEvent,
    };

    #[test]
    fn client_command_hello_serializes_with_stable_type_tag() {
        let value = serde_json::to_value(ClientCommand::Hello {
            protocol_version: "v1".into(),
            client_name: "codex-island-android".into(),
            client_version: "0.1.0".into(),
            auth_token: Some("secret".into()),
        })
        .expect("serialize hello");

        assert_eq!(
            value,
            json!({
                "type": "hello",
                "protocol_version": "v1",
                "client_name": "codex-island-android",
                "client_version": "0.1.0",
                "auth_token": "secret"
            })
        );
    }

    #[test]
    fn snapshot_event_round_trips() {
        let snapshot = sample_snapshot();
        let event = ServerEvent::Snapshot {
            snapshot: snapshot.clone(),
        };

        let encoded = serde_json::to_string(&event).expect("encode snapshot event");
        let decoded: ServerEvent = serde_json::from_str(&encoded).expect("decode snapshot event");

        assert_eq!(decoded, event);
        match decoded {
            ServerEvent::Snapshot { snapshot: decoded } => assert_eq!(decoded, snapshot),
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn app_server_request_keeps_arbitrary_json_params() {
        let command = ClientCommand::AppServerRequest {
            request_id: "req-1".into(),
            method: "thread/start".into(),
            params: json!({
                "cwd": "/repo",
                "input": [{"type": "text", "text": "hello"}]
            }),
        };

        let encoded = serde_json::to_value(&command).expect("encode request");
        assert_eq!(encoded["type"], Value::String("app_server_request".into()));
        assert_eq!(encoded["params"]["cwd"], Value::String("/repo".into()));
    }

    #[test]
    fn error_payload_omits_optional_fields_when_absent() {
        let event = ServerEvent::Error {
            error: ProtocolError {
                code: ErrorCode::Unauthorized,
                message: "auth token missing".into(),
                retryable: None,
                details: None,
            },
        };

        let value = serde_json::to_value(event).expect("encode error event");
        assert_eq!(
            value,
            json!({
                "type": "error",
                "error": {
                    "code": "unauthorized",
                    "message": "auth token missing"
                }
            })
        );
    }

    #[test]
    fn envelope_wraps_commands_without_changing_payload_shape() {
        let envelope = ProtocolEnvelope {
            id: "msg-1".into(),
            payload: ClientCommand::GetSnapshot,
        };

        let value = serde_json::to_value(envelope).expect("encode envelope");
        assert_eq!(
            value,
            json!({
                "id": "msg-1",
                "payload": {
                    "type": "get_snapshot"
                }
            })
        );
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
