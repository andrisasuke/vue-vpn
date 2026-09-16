use crate::{helper_update::HelperUpdater, models::*, native, policy, profile, storage::Store};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use zeroize::Zeroizing;

pub struct Credential {
    pub password: Zeroizing<String>,
    pub remember: bool,
}
pub struct Backend {
    pub store: Store,
    pub profiles: Vec<Profile>,
    pub sessions: Vec<Session>,
    pub logs: Vec<LogEntry>,
    pub helper: HelperStatus,
    credentials: HashMap<String, Credential>,
    helper_updater: HelperUpdater,
}
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
impl Backend {
    pub fn new(root: PathBuf) -> Result<Self> {
        let store = Store::new(root)?;
        let profiles = store.profiles()?;
        Ok(Self {
            store,
            profiles,
            sessions: vec![],
            logs: vec![],
            helper: HelperStatus {
                status: "not_registered".into(),
                message: "Enable the VPN helper to connect.".into(),
            },
            credentials: HashMap::new(),
            helper_updater: HelperUpdater::default(),
        })
    }
    pub fn log(&mut self, id: Option<String>, message: impl Into<String>) {
        self.logs.push(LogEntry {
            timestamp: now(),
            profile_id: id,
            message: message.into(),
        });
        if self.logs.len() > 300 {
            self.logs.remove(0);
        }
    }
    pub fn get(&self, id: &str) -> Result<Profile> {
        self.profiles
            .iter()
            .find(|p| p.id == id)
            .cloned()
            .ok_or_else(|| AppError::new("not_found", "Profile not found."))
    }
    pub fn active(&self, id: &str) -> bool {
        self.sessions
            .iter()
            .any(|s| s.profile_id == id && s.active())
    }
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            profiles: self.profiles.clone(),
            sessions: self.sessions.clone(),
            helper: self.helper.clone(),
            logs: self.logs.clone(),
        }
    }
    pub fn refresh_credentials(&mut self) {
        for p in &mut self.profiles {
            p.remembered = native::keychain("exists", &p.id, "")
                .ok()
                .and_then(|v| v["found"].as_bool())
                .unwrap_or(false);
        }
    }
    pub fn refresh(&mut self) -> Result<()> {
        self.refresh_inner(true)
    }
    fn refresh_inner(&mut self, allow_update: bool) -> Result<()> {
        let refreshed = self.helper_updater.refresh(allow_update)?;
        if self.helper.status != refreshed.helper.status
            && ["updating", "update_pending", "update_failed"]
                .contains(&refreshed.helper.status.as_str())
        {
            self.log(None, refreshed.helper.message.clone());
        }
        self.helper = refreshed.helper;
        if refreshed.updated {
            self.log(None, "VPN helper updated successfully.");
        }
        let Some(incoming) = refreshed.sessions else {
            if ["updating", "recovering"].contains(&self.helper.status.as_str()) {
                // No fresh snapshot: do not claim the old tunnels are connected.
                // Keep volatile credentials until the helper confirms final state.
                for session in &mut self.sessions {
                    if session.active() && session.status != SessionStatus::Disconnecting {
                        session.status = SessionStatus::Reconnecting;
                    }
                }
                return Ok(());
            }
            for s in &mut self.sessions {
                if s.active() {
                    s.status = SessionStatus::Error;
                    s.error = Some(self.helper.message.clone());
                    s.error_code = Some("helper_unavailable".into());
                }
            }
            self.credentials.clear();
            return Ok(());
        };
        for s in &incoming {
            if !self.profiles.iter().any(|p| p.id == s.profile_id) {
                continue;
            }
            let previous = self
                .sessions
                .iter()
                .find(|old| old.profile_id == s.profile_id && old.session_id == s.session_id);
            let changed =
                previous.is_none_or(|old| old.status != s.status || old.error_code != s.error_code);
            if changed {
                self.log(
                    Some(s.profile_id.clone()),
                    match &s.status {
                        SessionStatus::Connected => "Connected. Your VPN is ready.".into(),
                        SessionStatus::Error => s
                            .error
                            .clone()
                            .unwrap_or_else(|| "Connection failed.".into()),
                        other => format!(
                            "Connection status: {}",
                            serde_json::to_value(other)?.as_str().unwrap_or("unknown")
                        ),
                    },
                );
            }
            if s.status == SessionStatus::Connected {
                if let Some(c) = self.credentials.get_mut(&s.profile_id) {
                    if c.remember {
                        c.remember = false;
                        let result = native::keychain("set", &s.profile_id, &c.password);
                        if let Err(e) = result {
                            self.log(Some(s.profile_id.clone()), e.message);
                        } else if let Some(p) =
                            self.profiles.iter_mut().find(|p| p.id == s.profile_id)
                        {
                            p.remembered = true;
                        }
                    }
                }
            }
            if matches!(s.status, SessionStatus::Error | SessionStatus::Disconnected) {
                self.credentials.remove(&s.profile_id);
                if s.error_code.as_deref() == Some("AUTH_FAILED") {
                    let _ = native::keychain("delete", &s.profile_id, "");
                    if let Some(p) = self.profiles.iter_mut().find(|p| p.id == s.profile_id) {
                        p.remembered = false;
                    }
                }
            }
        }
        self.credentials
            .retain(|id, _| incoming.iter().any(|s| &s.profile_id == id && s.active()));
        self.sessions = incoming
            .into_iter()
            .filter(|s| self.profiles.iter().any(|p| p.id == s.profile_id))
            .collect();
        Ok(())
    }
    pub fn import(&mut self, path: PathBuf) -> Result<String> {
        if self.profiles.len() >= 32 {
            return Err(AppError::new("limit", "You can import up to 32 profiles."));
        }
        let mut imported = profile::read_profile(&path)?;
        if self.helper.status == "enabled" {
            self.evaluate(&mut imported.profile, &imported.content)?;
        }
        let content = Zeroizing::new(imported.content);
        self.store.save(&imported.profile, Some(&content))?;
        let id = imported.profile.id.clone();
        self.profiles.push(imported.profile);
        self.log(Some(id.clone()), "Profile imported.");
        Ok(id)
    }
    fn evaluate(&self, p: &mut Profile, content: &str) -> Result<()> {
        let value = native::request(
            json!({"version":1,"op":"validate","profileId":p.id,"profile":p,"content":content}),
        )?;
        if value["allowPasswordSave"].as_bool() == Some(false) {
            p.allow_password_save = false;
        }
        if let Some(username) = value["username"].as_str().filter(|s| !s.is_empty()) {
            p.username = username.into();
        }
        Ok(())
    }
    pub fn connect(&mut self, id: &str, password: Option<String>, remember: bool) -> Result<()> {
        self.refresh()?;
        if self.helper.status != "enabled" {
            return Err(AppError::new("helper_setup", self.helper.message.clone()));
        }
        if self.active(id) {
            return Err(AppError::new(
                "already_connected",
                "This profile is already active.",
            ));
        }
        let mut p = self.get(id)?;
        let others = self
            .profiles
            .iter()
            .filter(|other| self.active(&other.id))
            .cloned()
            .collect::<Vec<_>>();
        policy::conflict(&p, &others)?;
        let content = Zeroizing::new(self.store.content(id)?);
        self.evaluate(&mut p, &content)?;
        self.store.save(&p, None)?;
        if let Some(old) = self.profiles.iter_mut().find(|old| old.id == id) {
            *old = p.clone();
        }
        let secret = if p.auth_kind == AuthKind::Certificate {
            Zeroizing::new(String::new())
        } else if let Some(value) = password {
            Zeroizing::new(value)
        } else {
            let mut stored = native::keychain("get", id, "")?;
            match stored.get_mut("secret").map(Value::take) {
                Some(Value::String(value)) => Zeroizing::new(value),
                _ => {
                    return Err(AppError::new(
                        "credentials_required",
                        "Enter your PIN or password to connect.",
                    ))
                }
            }
        };
        if p.auth_kind != AuthKind::Certificate && secret.is_empty() {
            return Err(AppError::new(
                "credentials_required",
                "Enter your PIN or password.",
            ));
        }
        if secret.len() > 4096 {
            return Err(AppError::new("invalid_input", "Password is too long."));
        }
        if p.auth_kind == AuthKind::UsernamePassword && p.username.is_empty() {
            return Err(AppError::new(
                "username_required",
                "Set the username in profile settings.",
            ));
        }
        let session_id = uuid::Uuid::new_v4().to_string();
        native::request(
            json!({"version":1,"op":"connect","profileId":id,"sessionId":session_id,"profile":p,"content":&*content,"username":p.username,"password":&*secret}),
        )?;
        self.credentials.insert(
            id.to_string(),
            Credential {
                password: secret,
                remember: remember && p.allow_password_save,
            },
        );
        self.sessions.retain(|s| s.profile_id != id);
        self.sessions.push(Session {
            profile_id: id.into(),
            session_id,
            status: SessionStatus::Connecting,
            address: String::new(),
            interface: String::new(),
            connected_at: None,
            attempts: 0,
            bytes_in: 0,
            bytes_out: 0,
            error: None,
            error_code: None,
            effective_routes: vec![],
            effective_dns: DnsSettings::default(),
        });
        Ok(())
    }
    pub fn disconnect(&mut self, id: &str) -> Result<()> {
        self.get(id)?;
        native::request(json!({"version":1,"op":"disconnect","profileId":id}))?;
        self.credentials.remove(id);
        self.refresh()?;
        if self
            .sessions
            .iter()
            .any(|s| s.profile_id == id && s.error_code.as_deref() == Some("cleanup_failed"))
        {
            return Err(AppError::new(
                "cleanup_failed",
                "VPN network cleanup has not finished. Retry Connect or Disconnect to resume cleanup.",
            ));
        }
        Ok(())
    }
    // Quit, delete, and profile changes must wait for route cleanup, while the
    // helper continues to answer snapshots/cancellations on its control queue.
    fn wait_for_disconnect(&mut self, id: Option<&str>) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let value = native::request(json!({"version":1,"op":"snapshot"}))?;
            let sessions: Vec<Session> = serde_json::from_value(value["sessions"].clone())?;
            let relevant = |s: &&Session| id.is_none_or(|id| s.profile_id == id);
            if sessions
                .iter()
                .filter(relevant)
                .any(|s| s.error_code.as_deref() == Some("cleanup_failed"))
            {
                return Err(AppError::new(
                    "cleanup_failed",
                    "VPN network cleanup has not finished. Retry Connect or Disconnect to resume cleanup.",
                ));
            }
            if !sessions.iter().filter(relevant).any(Session::active) {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(AppError::new(
                    "cleanup_pending",
                    "VPN cleanup is still running. Wait for Disconnected, then retry this action.",
                ));
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }
    pub fn disconnect_all(&mut self) -> Result<()> {
        if self.helper.status == "updating" {
            return Err(AppError::new(
                "helper_updating",
                "Wait for the VPN helper update to finish before quitting or disabling it.",
            ));
        }
        if self.sessions.iter().any(Session::active)
            || ["enabled", "update_pending"].contains(&self.helper.status.as_str())
        {
            native::request(json!({"version":1,"op":"disconnect_all"}))?;
            self.wait_for_disconnect(None)?;
        }
        self.credentials.clear();
        // Quit/disable also use this path. Do not begin an asynchronous replacement
        // immediately before the app exits; ordinary polling handles UI disconnects.
        self.refresh_inner(false)?;
        if self
            .sessions
            .iter()
            .any(|s| s.error_code.as_deref() == Some("cleanup_failed"))
        {
            return Err(AppError::new(
                "cleanup_failed",
                "VPN network cleanup has not finished. Retry Connect or Disconnect to resume cleanup.",
            ));
        }
        Ok(())
    }
    pub fn update(&mut self, id: &str, mut update: ProfileUpdate) -> Result<()> {
        policy::validate_update(&mut update)?;
        let old = self.get(id)?;
        let mut p = old.clone();
        p.name = update.name;
        p.username = update.username;
        p.routing_mode = update.routing_mode;
        p.routes = update.routes;
        p.dns = update.dns;
        p.allow_legacy_cipher = update.allow_legacy_cipher;
        let reconnect = self.active(id)
            && (old.username != p.username
                || old.routing_mode != p.routing_mode
                || old.routes != p.routes
                || old.dns != p.dns
                || old.allow_legacy_cipher != p.allow_legacy_cipher);
        if reconnect {
            let others = self
                .profiles
                .iter()
                .filter(|other| other.id != id && self.active(&other.id))
                .cloned()
                .collect::<Vec<_>>();
            policy::conflict(&p, &others)?;
        }
        // Copy the current session credential before disconnect clears it. Never write it to disk.
        let credential = if reconnect {
            self.credentials
                .get(id)
                .map(|c| (Zeroizing::new(c.password.to_string()), c.remember))
        } else {
            None
        };
        if reconnect {
            self.disconnect(id)?;
            self.wait_for_disconnect(Some(id))?;
        }
        self.store.save(&p, None)?;
        *self.profiles.iter_mut().find(|x| x.id == id).unwrap() = p;
        if reconnect {
            self.connect(
                id,
                credential.as_ref().map(|c| c.0.to_string()),
                credential.is_some_and(|c| c.1),
            )?;
        }
        Ok(())
    }
    pub fn forget(&mut self, id: &str) -> Result<()> {
        self.get(id)?;
        native::keychain("delete", id, "")?;
        if let Some(c) = self.credentials.get_mut(id) {
            c.remember = false;
        }
        self.profiles
            .iter_mut()
            .find(|p| p.id == id)
            .unwrap()
            .remembered = false;
        Ok(())
    }
    pub fn delete(&mut self, id: &str) -> Result<()> {
        self.get(id)?;
        if self.active(id) {
            self.disconnect(id)?;
            self.wait_for_disconnect(Some(id))?;
        }
        self.forget(id)?;
        self.store.delete(id)?;
        self.profiles.retain(|p| p.id != id);
        self.sessions.retain(|s| s.profile_id != id);
        self.credentials.remove(id);
        Ok(())
    }
    pub fn helper_action(&mut self, op: &str) -> Result<HelperStatus> {
        if ![
            "status",
            "register",
            "settings",
            "unregister",
            "retry_update",
        ]
        .contains(&op)
        {
            return Err(AppError::new("invalid_input", "Unknown helper action."));
        }
        if op == "retry_update" || (op == "register" && self.helper.status == "unavailable") {
            self.helper_updater.retry()?;
            self.refresh()?;
            return Ok(self.helper.clone());
        }
        if op == "unregister" {
            self.disconnect_all()?;
        }
        self.helper = native::service(op)?;
        if ["register", "unregister"].contains(&op) && self.helper.status != "updating" {
            self.helper_updater = HelperUpdater::default();
        }
        if op == "status" {
            self.refresh()?;
        }
        Ok(self.helper.clone())
    }
}
