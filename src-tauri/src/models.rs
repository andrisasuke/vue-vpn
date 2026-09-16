use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RoutingMode {
    All,
    Selected,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthKind {
    Pin,
    UsernamePassword,
    Certificate,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Route {
    pub address: Ipv4Addr,
    pub prefix: u8,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DnsSettings {
    pub servers: Vec<Ipv4Addr>,
    pub domains: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub auth_kind: AuthKind,
    pub username: String,
    pub routing_mode: RoutingMode,
    pub routes: Vec<Route>,
    pub dns: DnsSettings,
    pub protocol: String,
    pub server: String,
    pub allow_password_save: bool,
    pub allow_legacy_cipher: bool,
    pub warnings: Vec<String>,
    #[serde(default)]
    pub remembered: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileUpdate {
    pub name: String,
    pub username: String,
    pub routing_mode: RoutingMode,
    pub routes: Vec<Route>,
    pub dns: DnsSettings,
    pub allow_legacy_cipher: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Disconnected,
    AwaitingCredentials,
    Connecting,
    Connected,
    Reconnecting,
    Disconnecting,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub profile_id: String,
    pub session_id: String,
    pub status: SessionStatus,
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub interface: String,
    #[serde(default)]
    pub connected_at: Option<u64>,
    #[serde(default)]
    pub attempts: u32,
    #[serde(default)]
    pub bytes_in: u64,
    #[serde(default)]
    pub bytes_out: u64,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub error_code: Option<String>,
    #[serde(default)]
    pub effective_routes: Vec<Route>,
    #[serde(default)]
    pub effective_dns: DnsSettings,
}

impl Session {
    pub fn active(&self) -> bool {
        matches!(
            self.status,
            SessionStatus::Connecting
                | SessionStatus::Connected
                | SessionStatus::Reconnecting
                | SessionStatus::Disconnecting
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HelperStatus {
    pub status: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogEntry {
    pub timestamp: u64,
    pub profile_id: Option<String>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub profiles: Vec<Profile>,
    pub sessions: Vec<Session>,
    pub helper: HelperStatus,
    pub logs: Vec<LogEntry>,
}

#[derive(Debug, Clone, Serialize, thiserror::Error)]
#[error("{message}")]
#[serde(rename_all = "camelCase")]
pub struct AppError {
    pub code: String,
    pub message: String,
}
impl AppError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}
pub type Result<T> = std::result::Result<T, AppError>;
impl From<std::io::Error> for AppError {
    fn from(e: std::io::Error) -> Self {
        Self::new("storage", e.to_string())
    }
}
impl From<serde_json::Error> for AppError {
    fn from(e: serde_json::Error) -> Self {
        Self::new("data", e.to_string())
    }
}
