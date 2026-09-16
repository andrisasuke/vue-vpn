use crate::{models::*, native};
use serde::Deserialize;
use serde_json::json;
use std::time::{Duration, Instant};

const UPDATE_TIMEOUT: Duration = Duration::from_secs(45);
const MAX_REGISTRATIONS: u8 = 3;
const REGISTRATION_INTERVAL: Duration = Duration::from_secs(2);
const MAX_REPLACEMENT_RETRIES: u8 = 2;

#[derive(Default)]
pub struct HelperUpdater {
    expected: Option<Option<String>>,
    attempted: bool,
    replacement_started: bool,
    replacement_retries: u8,
    next_replacement: Option<Instant>,
    repair_requested: bool,
    registrations: u8,
    next_registration: Option<Instant>,
    registration_message: Option<String>,
    started: Option<Instant>,
    verification_started: Option<Instant>,
    verification_reconnected: bool,
    waiting_for_stop_completion: bool,
    failure: Option<String>,
    was_available: bool,
    unavailable_since: Option<Instant>,
    unavailable_count: u8,
    recovery_attempted: bool,
}

pub struct HelperRefresh {
    pub helper: HelperStatus,
    pub sessions: Option<Vec<Session>>,
    pub updated: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HelperSnapshot {
    #[serde(default)]
    build_id: Option<String>, // Legacy helpers do not report an identity.
    sessions: Vec<Session>,
}

fn state(status: &str, message: &str) -> HelperStatus {
    HelperStatus {
        status: status.into(),
        message: message.into(),
    }
}
fn result(helper: HelperStatus, sessions: Option<Vec<Session>>) -> HelperRefresh {
    HelperRefresh {
        helper,
        sessions,
        updated: false,
    }
}

impl HelperUpdater {
    pub fn retry(&mut self) -> Result<()> {
        let status = native::service("reset_update")?;
        if status.status == "updating" {
            return Err(AppError::new(
                "helper_updating",
                "The helper update is still finishing. Please wait.",
            ));
        }
        self.attempted = false;
        self.replacement_started = false;
        self.replacement_retries = 0;
        self.next_replacement = None;
        // Retry is also authorization to finish a registration lost during update.
        // Do not fall back to a separate Enable button when the job is absent.
        self.repair_requested = true;
        self.registrations = 0;
        self.next_registration = None;
        self.registration_message = None;
        self.started = None;
        self.verification_started = None;
        self.verification_reconnected = false;
        self.waiting_for_stop_completion = false;
        self.failure = None;
        self.expected = None;
        self.unavailable_since = None;
        self.unavailable_count = 0;
        self.recovery_attempted = false;
        Ok(())
    }

    pub fn refresh(&mut self, allow_update: bool) -> Result<HelperRefresh> {
        self.refresh_at(allow_update, Instant::now())
    }

    fn fail(&mut self, message: String, sessions: Option<Vec<Session>>) -> HelperRefresh {
        self.failure = Some(message.clone());
        result(state("update_failed", &message), sessions)
    }

    fn bundled(&mut self) -> Result<bool> {
        if self.expected.is_none() {
            self.expected = Some(native::bundled_helper_id()?);
        }
        Ok(self.expected.as_ref().and_then(Option::as_ref).is_some())
    }

    fn verified(&mut self, helper: HelperStatus, sessions: Vec<Session>) -> HelperRefresh {
        let updated = self.attempted;
        self.attempted = false;
        self.replacement_started = false;
        self.replacement_retries = 0;
        self.next_replacement = None;
        self.repair_requested = false;
        self.registrations = 0;
        self.next_registration = None;
        self.registration_message = None;
        self.started = None;
        self.verification_started = None;
        self.verification_reconnected = false;
        self.waiting_for_stop_completion = false;
        self.failure = None;
        self.was_available = true;
        self.unavailable_since = None;
        self.unavailable_count = 0;
        HelperRefresh {
            helper,
            sessions: Some(sessions),
            updated,
        }
    }

    fn verification_timed_out(&mut self, now: Instant) -> bool {
        let start = *self.verification_started.get_or_insert(now);
        now.duration_since(start) >= UPDATE_TIMEOUT
    }

    fn register_missing(
        &mut self,
        service: HelperStatus,
        allow_update: bool,
        now: Instant,
    ) -> HelperRefresh {
        if !allow_update {
            return result(service, None);
        }
        // Validate both the signed executable and the launch daemon plist before
        // treating NotFound as a stale registration rather than an incomplete app.
        match self.bundled() {
            Ok(true) => (),
            Ok(false) => return result(service, None), // Unbundled dev executable.
            Err(e) => return self.fail(e.message, None),
        }
        self.attempted = true;
        // Registration gets its own window after unregister finishes.
        if self.registrations == 0 {
            self.started = Some(now);
        }
        let start = *self.started.get_or_insert(now);
        if now.duration_since(start) >= UPDATE_TIMEOUT {
            let detail = self
                .registration_message
                .as_deref()
                .unwrap_or("macOS did not register the VPN helper.");
            return self.fail(
                format!("{detail} Registration did not finish in time. Retry the helper update."),
                None,
            );
        }
        if self.next_registration.is_some_and(|next| now < next) {
            return result(
                state("updating", "Waiting for macOS to register the VPN helper…"),
                None,
            );
        }
        if self.registrations >= MAX_REGISTRATIONS {
            // macOS can finish asynchronously after the last register call.
            // Stop issuing registrations, but keep observing until the deadline.
            return result(
                state(
                    "updating",
                    "Waiting for macOS to finish registering the VPN helper…",
                ),
                None,
            );
        }
        self.registrations += 1;
        self.next_registration = Some(now + REGISTRATION_INTERVAL);
        match native::service("register_update") {
            Ok(helper) => {
                self.registration_message = Some(helper.message.clone());
                match helper.status.as_str() {
                    "requires_approval" => {
                        self.started = None;
                        self.verification_started = None;
                        self.verification_reconnected = false;
                        result(helper, None)
                    }
                    "enabled" | "registration_pending" | "not_found" | "not_registered" =>
                    // Registration alone is not success: the next snapshot
                    // must confirm the running executable's fingerprint.
                    {
                        result(
                            state("updating", "Registering and verifying the VPN helper…"),
                            None,
                        )
                    }
                    _ => self.fail(helper.message, None),
                }
            }
            Err(e) => self.fail(e.message, None),
        }
    }

    fn refresh_at(&mut self, allow_update: bool, now: Instant) -> Result<HelperRefresh> {
        let service = native::service("status")?;
        // An unregister completion arriving after our UI timeout still owns one
        // unfinished replacement. Finish its registration without a new restart.
        if self.waiting_for_stop_completion
            && service.status == "registration_pending"
            && allow_update
        {
            self.waiting_for_stop_completion = false;
            self.failure = None;
            self.started = Some(now);
            self.registrations = 0;
            self.next_registration = None;
        }
        // Failures prevent another restart, but a delayed successful startup
        // can clear them through read-only identity verification.
        if let Some(message) = self.failure.clone() {
            let snapshot = if ["enabled", "update_failed", "update_retry_pending"]
                .contains(&service.status.as_str())
            {
                native::request(json!({"version":1,"op":"snapshot"}))
                    .ok()
                    .and_then(|value| serde_json::from_value::<HelperSnapshot>(value).ok())
            } else {
                None
            };
            if let Some(snapshot) = snapshot {
                let matching = self.bundled().unwrap_or(false)
                    && self.expected.as_ref().and_then(Option::as_ref)
                        == snapshot.build_id.as_ref();
                let clean = !snapshot
                    .sessions
                    .iter()
                    .any(|s| s.error_code.as_deref() == Some("cleanup_failed"));
                if matching && clean {
                    let service = if service.status == "enabled" {
                        service
                    } else {
                        native::service("reset_update")?
                    };
                    if service.status == "enabled" {
                        return Ok(self.verified(service, snapshot.sessions));
                    }
                }
                return Ok(result(
                    state("update_failed", &message),
                    Some(snapshot.sessions),
                ));
            }
            return Ok(result(state("update_failed", &message), None));
        }
        if service.status == "update_failed" {
            return Ok(self.fail(service.message, None));
        }
        if service.status == "update_retry_pending" {
            // Retry only errors classified as temporary by the native bridge,
            // and only within the replacement this coordinator already started.
            if !self.replacement_started || self.replacement_retries >= MAX_REPLACEMENT_RETRIES {
                return Ok(self.fail(service.message, None));
            }
            if !allow_update {
                return Ok(result(
                    state("updating", "Waiting to retry the VPN helper update…"),
                    None,
                ));
            }
            let next = *self
                .next_replacement
                .get_or_insert(now + REGISTRATION_INTERVAL);
            if now < next {
                return Ok(result(
                    state(
                        "updating",
                        "macOS is busy. Retrying the VPN helper update automatically…",
                    ),
                    None,
                ));
            }
            let reset = native::service("reset_update")?;
            if reset.status == "updating" {
                return Ok(result(reset, None));
            }
            // A user disabling the service or revoking approval ends recovery.
            if ["requires_approval", "not_registered"].contains(&reset.status.as_str()) {
                self.attempted = false;
                self.replacement_started = false;
                return Ok(result(reset, None));
            }
            self.replacement_retries += 1;
            self.next_replacement = None;
            self.started = Some(now);
            self.verification_started = None;
            self.verification_reconnected = false;
            return Ok(match native::service("replace") {
                Ok(helper) => result(helper, None),
                Err(e) => self.fail(e.message, None),
            });
        }
        if service.status == "updating" {
            if self
                .started
                .is_some_and(|start| now.duration_since(start) >= UPDATE_TIMEOUT)
            {
                self.waiting_for_stop_completion = self.replacement_started;
                return Ok(self.fail("The helper update took too long. Retry after macOS finishes stopping the previous helper.".into(), None));
            }
            return Ok(result(service, None));
        }
        if service.status == "registration_pending"
            || service.status == "not_found"
            || (service.status == "not_registered" && (self.attempted || self.repair_requested))
        {
            return Ok(self.register_missing(service, allow_update, now));
        }
        if service.status != "enabled" {
            // Never re-enable a helper the user disabled, or bypass macOS consent.
            // Approval may take arbitrarily long; restart the verification window.
            if service.status == "requires_approval" {
                self.started = None;
                self.verification_started = None;
                self.verification_reconnected = false;
            }
            return Ok(result(service, None));
        }
        let response = match native::request(json!({"version":1,"op":"snapshot"})) {
            Ok(value) => value,
            Err(e) => {
                if self.attempted {
                    if !self.verification_timed_out(now) {
                        return Ok(result(
                            state("updating", "Waiting for the updated VPN helper…"),
                            None,
                        ));
                    }
                    return Ok(self.fail(
                        "The updated VPN helper did not respond. Retry the helper update.".into(),
                        None,
                    ));
                }
                if !["helper_unavailable", "helper_timeout"].contains(&e.code.as_str()) {
                    return Ok(result(state("unavailable", &e.message), None));
                }
                // A replaced app has no successful snapshot yet. An already
                // enabled service plus a valid signed bundle is enough to enter
                // bounded startup recovery; no manual Repair is needed first.
                if !self.was_available {
                    match self.bundled() {
                        Ok(true) => (),
                        Ok(false) => return Ok(result(state("unavailable", &e.message), None)),
                        Err(e) => return Ok(self.fail(e.message, None)),
                    }
                }
                let since = *self.unavailable_since.get_or_insert(now);
                self.unavailable_count = self.unavailable_count.saturating_add(1);
                if self.repair_requested
                    || (self.unavailable_count >= 3
                        && now.duration_since(since) >= Duration::from_secs(6))
                {
                    if !allow_update {
                        return Ok(result(state("unavailable", &e.message), None));
                    }
                    if self.recovery_attempted {
                        return Ok(self.fail("The VPN helper is still unavailable after recovery. Use Repair helper to retry.".into(), None));
                    }
                    match self.bundled() {
                        Ok(true) => (),
                        Ok(false) => return Ok(result(state("unavailable", &e.message), None)),
                        Err(e) => return Ok(self.fail(e.message, None)),
                    }
                    self.recovery_attempted = true;
                    self.attempted = true;
                    self.replacement_started = true;
                    self.started = Some(now);
                    self.verification_started = None;
                    self.verification_reconnected = false;
                    return Ok(match native::service("replace") {
                        Ok(helper) => result(helper, None),
                        Err(e) => self.fail(e.message, None),
                    });
                }
                return Ok(result(
                    if self.was_available {
                        state("recovering", "Reconnecting to the VPN helper…")
                    } else {
                        state("updating", "Checking the VPN helper after app startup…")
                    },
                    None,
                ));
            }
        };
        let snapshot: HelperSnapshot = serde_json::from_value(response)?;
        self.was_available = true;
        self.unavailable_since = None;
        self.unavailable_count = 0;
        if let Err(e) = self.bundled() {
            return Ok(self.fail(e.message, Some(snapshot.sessions)));
        }
        let expected = self.expected.as_ref().and_then(Option::as_ref);
        if expected.is_none() || expected == snapshot.build_id.as_ref() {
            return Ok(self.verified(service, snapshot.sessions));
        }
        if self.replacement_started {
            if self.verification_timed_out(now) {
                return Ok(self.fail("The running helper still differs from this app after updating. Retry the helper update.".into(), Some(snapshot.sessions)));
            }
            if !self.verification_reconnected && !snapshot.sessions.iter().any(Session::active) {
                // A cached XPC channel can still point at the old idle process.
                // Reopen it once; this does not unregister/register the service.
                native::service("reconnect")?;
                self.verification_reconnected = true;
            }
            return Ok(result(
                state(
                    "updating",
                    "Waiting for the new VPN helper to start and verify…",
                ),
                Some(snapshot.sessions),
            ));
        }
        // Inspect all helper sessions, including ones absent from local profiles.
        // No automatic disconnect/reconnect and no credential access during update.
        if snapshot.sessions.iter().any(Session::active) || !allow_update {
            return Ok(result(state("update_pending", "A VPN helper update is ready. It will install automatically after all VPN connections are disconnected."), Some(snapshot.sessions)));
        }
        if snapshot
            .sessions
            .iter()
            .any(|s| s.error_code.as_deref() == Some("cleanup_failed"))
        {
            return Ok(self.fail("VPN network cleanup must finish before the helper can update. Restart macOS, then retry.".into(), Some(snapshot.sessions)));
        }
        self.attempted = true;
        self.replacement_started = true;
        self.registrations = 0;
        self.next_registration = None;
        self.started = Some(now);
        self.verification_started = None;
        self.verification_reconnected = false;
        match native::service("replace") {
            Ok(helper) => Ok(result(helper, Some(snapshot.sessions))),
            Err(e) => Ok(self.fail(e.message, Some(snapshot.sessions))),
        }
    }
}

#[cfg(test)]
mod tests;
