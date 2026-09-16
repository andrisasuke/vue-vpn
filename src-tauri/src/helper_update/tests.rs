use super::*;
use serde_json::Value;
use std::sync::{Arc, Mutex};

struct Fake {
    status: String,
    bundled: Option<String>,
    running: Option<String>,
    sessions: Vec<Value>,
    calls: Vec<String>,
    snapshot_error: bool,
    replace_error: bool,
    identity_error: bool,
    registration_status: String,
    registration_error: bool,
}

fn setup() -> (HelperUpdater, Arc<Mutex<Fake>>) {
    let fake = Arc::new(Mutex::new(Fake {
        status: "enabled".into(),
        bundled: Some("current".into()),
        running: Some("current".into()),
        sessions: vec![],
        calls: vec![],
        snapshot_error: false,
        replace_error: false,
        identity_error: false,
        registration_status: "enabled".into(),
        registration_error: false,
    }));
    let handle = fake.clone();
    native::testing::install(Box::new(move |kind, input| {
        let mut f = handle.lock().unwrap();
        let op = input["op"].as_str().unwrap();
        f.calls.push(format!("{kind}:{op}"));
        match (kind, op) {
            ("identity", _) => if f.identity_error { Err(AppError::new("helper_bundle", "Invalid bundled signature")) } else { Ok(json!({"buildId":f.bundled})) },
            ("request", "snapshot") => if f.snapshot_error { Err(AppError::new("helper_unavailable", "Unavailable")) } else { Ok(json!({"buildId":f.running,"sessions":f.sessions})) },
            ("service", "reconnect") => Ok(json!({"status":f.status,"message":"Mock reconnect"})),
            ("service", "status") => Ok(json!({"status":f.status,"message":"Mock helper"})),
            ("service", "replace") => {
                if f.replace_error { return Err(AppError::new("helper_setup", "Mock replace failure")); }
                f.status = "updating".into();
                Ok(json!({"status":"updating","message":"Updating"}))
            }
            ("service", "reset_update") => {
                if ["update_failed", "update_retry_pending"].contains(&f.status.as_str()) { f.status = "enabled".into(); }
                Ok(json!({"status":f.status,"message":"Mock reset"}))
            }
            ("service", "register_update") => {
                if f.registration_error { return Err(AppError::new("helper_setup", "Invalid signature or authorization")); }
                f.status = f.registration_status.clone();
                Ok(json!({"status":f.status,"message":"Mock registration"}))
            }
            _ => panic!("Unexpected native operation: {kind}:{op}. Updates must not touch VPN connections or credentials."),
        }
    }));
    (HelperUpdater::default(), fake)
}
fn replacements(fake: &Arc<Mutex<Fake>>) -> usize {
    fake.lock()
        .unwrap()
        .calls
        .iter()
        .filter(|c| *c == "service:replace")
        .count()
}
fn session(status: &str) -> Value {
    json!({"profileId":"profile-not-in-app","sessionId":"s1","status":status})
}

#[test]
fn matching_helper_and_unbundled_dev_do_not_restart() {
    let (mut u, f) = setup();
    for _ in 0..3 {
        assert_eq!(u.refresh(true).unwrap().helper.status, "enabled");
    }
    assert_eq!(replacements(&f), 0);
    assert_eq!(
        f.lock()
            .unwrap()
            .calls
            .iter()
            .filter(|c| *c == "identity:identity")
            .count(),
        1
    );
    let (mut u, f) = setup();
    f.lock().unwrap().bundled = None;
    f.lock().unwrap().running = Some("older".into());
    assert_eq!(u.refresh(true).unwrap().helper.status, "enabled");
    assert_eq!(replacements(&f), 0);
}

#[test]
fn replaces_old_or_legacy_helper_once_then_verifies_identity() {
    for running in [Some("older".into()), None] {
        let (mut u, f) = setup();
        f.lock().unwrap().running = running;
        assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
        for _ in 0..3 {
            assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
        }
        assert_eq!(replacements(&f), 1);
        f.lock().unwrap().status = "enabled".into();
        f.lock().unwrap().running = Some("current".into());
        let ready = u.refresh(true).unwrap();
        assert_eq!(ready.helper.status, "enabled");
        assert!(ready.updated);
        assert!(!u.refresh(true).unwrap().updated);
        assert_eq!(replacements(&f), 1);
    }
}

#[test]
fn waits_for_every_active_session_and_does_not_replace_during_quit() {
    for status in ["connecting", "connected", "reconnecting", "disconnecting"] {
        let (mut u, f) = setup();
        f.lock().unwrap().running = None;
        f.lock().unwrap().sessions = vec![session(status)];
        let pending = u.refresh(true).unwrap();
        assert_eq!(pending.helper.status, "update_pending");
        assert!(pending.sessions.unwrap()[0].active());
        assert_eq!(replacements(&f), 0);
        f.lock().unwrap().sessions[0]["status"] = json!("disconnected");
        assert_eq!(u.refresh(false).unwrap().helper.status, "update_pending");
        assert_eq!(replacements(&f), 0);
        assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
        assert_eq!(replacements(&f), 1);
    }
}

#[test]
fn disabled_or_unapproved_helper_is_never_automatically_registered() {
    for status in ["not_registered", "requires_approval"] {
        let (mut u, f) = setup();
        f.lock().unwrap().status = status.into();
        assert_eq!(u.refresh(true).unwrap().helper.status, status);
        assert_eq!(f.lock().unwrap().calls, vec!["service:status"]);
    }
}

fn registrations(fake: &Arc<Mutex<Fake>>) -> usize {
    fake.lock()
        .unwrap()
        .calls
        .iter()
        .filter(|c| *c == "service:register_update")
        .count()
}

#[test]
fn not_found_on_launch_repairs_valid_bundle_without_stopping_a_helper() {
    let (mut u, f) = setup();
    f.lock().unwrap().status = "not_found".into();
    assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
    assert_eq!(registrations(&f), 1);
    assert_eq!(replacements(&f), 0);
    let verified = u.refresh(true).unwrap();
    assert_eq!(verified.helper.status, "enabled");
    assert!(verified.updated);
    u.refresh(true).unwrap();
    assert_eq!(registrations(&f), 1);
}

#[test]
fn missing_registration_after_stop_is_retried_then_verified_without_manual_enable() {
    for missing in ["registration_pending", "not_found", "not_registered"] {
        let (mut u, f) = setup();
        let now = Instant::now();
        f.lock().unwrap().running = None;
        u.refresh_at(true, now).unwrap();
        f.lock().unwrap().status = missing.into(); // unregister completion
        f.lock().unwrap().registration_status = "not_found".into();
        assert_eq!(u.refresh_at(true, now).unwrap().helper.status, "updating");
        assert_eq!(registrations(&f), 1);
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(1))
                .unwrap()
                .helper
                .status,
            "updating"
        );
        assert_eq!(registrations(&f), 1); // No tight registration loop.
        f.lock().unwrap().registration_status = "enabled".into();
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(2))
                .unwrap()
                .helper
                .status,
            "updating"
        );
        f.lock().unwrap().running = Some("current".into());
        let verified = u.refresh_at(true, now + Duration::from_secs(3)).unwrap();
        assert_eq!(verified.helper.status, "enabled");
        assert!(verified.updated);
        assert_eq!(registrations(&f), 2);
        assert_eq!(replacements(&f), 1);
        assert!(!f
            .lock()
            .unwrap()
            .calls
            .iter()
            .any(|c| c == "service:register" || c == "service:reset_update"));
    }
}

#[test]
fn retry_finishes_lost_registration_without_a_separate_enable_action() {
    let (mut u, f) = setup();
    f.lock().unwrap().running = None;
    u.refresh(true).unwrap();
    f.lock().unwrap().status = "update_failed".into();
    assert_eq!(u.refresh(true).unwrap().helper.status, "update_failed");
    f.lock().unwrap().status = "not_registered".into();
    u.retry().unwrap();
    assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
    f.lock().unwrap().running = Some("current".into());
    assert!(u.refresh(true).unwrap().updated);
    assert_eq!(registrations(&f), 1);
    assert_eq!(replacements(&f), 1);
}

#[test]
fn persistent_not_found_has_bounded_registration_retries() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().status = "not_found".into();
    f.lock().unwrap().registration_status = "registration_pending".into();
    for seconds in [0, 2, 4] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "updating"
        );
    }
    for seconds in [6, 8, 10, 44] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "updating"
        );
    }
    for seconds in [46, 60] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "update_failed"
        );
    }
    assert_eq!(registrations(&f), 3);
    assert_eq!(replacements(&f), 0);
    u.retry().unwrap();
    f.lock().unwrap().registration_status = "enabled".into();
    u.refresh_at(true, now + Duration::from_secs(62)).unwrap();
    assert!(
        u.refresh_at(true, now + Duration::from_secs(63))
            .unwrap()
            .updated
    );
}

#[test]
fn registration_denial_waits_for_approval_and_permanent_errors_do_not_retry() {
    let (mut u, f) = setup();
    f.lock().unwrap().status = "not_found".into();
    f.lock().unwrap().registration_status = "requires_approval".into();
    assert_eq!(u.refresh(true).unwrap().helper.status, "requires_approval");
    for _ in 0..3 {
        assert_eq!(u.refresh(true).unwrap().helper.status, "requires_approval");
    }
    assert_eq!(registrations(&f), 1);
    f.lock().unwrap().status = "enabled".into();
    assert!(u.refresh(true).unwrap().updated);
    let (mut u, f) = setup();
    f.lock().unwrap().status = "not_found".into();
    f.lock().unwrap().registration_error = true;
    for _ in 0..3 {
        assert_eq!(u.refresh(true).unwrap().helper.status, "update_failed");
    }
    assert_eq!(registrations(&f), 1);
}

#[test]
fn not_found_does_not_install_from_invalid_bundle_dev_or_during_quit() {
    let (mut u, f) = setup();
    f.lock().unwrap().status = "not_found".into();
    assert_eq!(u.refresh(false).unwrap().helper.status, "not_found");
    assert_eq!(registrations(&f), 0);
    f.lock().unwrap().identity_error = true;
    assert_eq!(u.refresh(true).unwrap().helper.status, "update_failed");
    assert_eq!(registrations(&f), 0);
    let (mut u, f) = setup();
    f.lock().unwrap().status = "not_found".into();
    f.lock().unwrap().bundled = None;
    assert_eq!(u.refresh(true).unwrap().helper.status, "not_found");
    assert_eq!(registrations(&f), 0);
}

#[test]
fn recovered_registration_still_defers_replacement_of_an_active_old_helper() {
    let (mut u, f) = setup();
    f.lock().unwrap().status = "not_found".into();
    f.lock().unwrap().running = None;
    f.lock().unwrap().sessions = vec![session("connected")];
    u.refresh(true).unwrap();
    let pending = u.refresh(true).unwrap();
    assert_eq!(pending.helper.status, "update_pending");
    assert!(pending.sessions.unwrap()[0].active());
    assert_eq!(replacements(&f), 0);
    f.lock().unwrap().sessions.clear();
    assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
    assert_eq!(replacements(&f), 1);
}

#[test]
fn approval_after_replacement_waits_for_user_without_repeated_registration() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().running = None;
    u.refresh_at(true, now).unwrap();
    f.lock().unwrap().status = "requires_approval".into();
    assert_eq!(
        u.refresh_at(true, now + Duration::from_secs(300))
            .unwrap()
            .helper
            .status,
        "requires_approval"
    );
    f.lock().unwrap().status = "enabled".into();
    f.lock().unwrap().running = Some("current".into());
    assert!(
        u.refresh_at(true, now + Duration::from_secs(600))
            .unwrap()
            .updated
    );
    assert_eq!(replacements(&f), 1);
}

#[test]
fn replacement_failure_is_latched_and_retry_is_explicit() {
    let (mut u, f) = setup();
    f.lock().unwrap().running = None;
    f.lock().unwrap().replace_error = true;
    assert_eq!(u.refresh(true).unwrap().helper.status, "update_failed");
    for _ in 0..3 {
        assert_eq!(u.refresh(true).unwrap().helper.status, "update_failed");
    }
    assert_eq!(replacements(&f), 1);
    f.lock().unwrap().replace_error = false;
    u.retry().unwrap();
    assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
    assert_eq!(replacements(&f), 2);
    assert_eq!(u.retry().unwrap_err().code, "helper_updating");
}

#[test]
fn async_failure_and_wrong_identity_never_report_success() {
    for status in ["update_failed", "enabled"] {
        let (mut u, f) = setup();
        let now = Instant::now();
        f.lock().unwrap().running = None;
        u.refresh_at(true, now).unwrap();
        f.lock().unwrap().status = status.into();
        let first = u.refresh_at(true, now + Duration::from_secs(1)).unwrap();
        assert_eq!(
            first.helper.status,
            if status == "enabled" {
                "updating"
            } else {
                "update_failed"
            }
        );
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(46))
                .unwrap()
                .helper
                .status,
            "update_failed"
        );
        assert_eq!(replacements(&f), 1);
    }
}

#[test]
fn waiting_and_xpc_failure_have_bounded_verification_without_sleeping() {
    for status in ["updating", "enabled"] {
        let (mut u, f) = setup();
        let now = Instant::now();
        f.lock().unwrap().running = None;
        u.refresh_at(true, now).unwrap();
        f.lock().unwrap().status = status.into();
        f.lock().unwrap().snapshot_error = true;
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(1))
                .unwrap()
                .helper
                .status,
            "updating"
        );
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(46))
                .unwrap()
                .helper
                .status,
            "update_failed"
        );
        assert_eq!(replacements(&f), 1);
    }
}

#[test]
fn startup_probe_bad_signature_and_cleanup_failure_do_not_restart_immediately() {
    let (mut u, f) = setup();
    f.lock().unwrap().snapshot_error = true;
    assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
    assert_eq!(replacements(&f), 0);
    let (mut u, f) = setup();
    f.lock().unwrap().identity_error = true;
    f.lock().unwrap().sessions = vec![session("connected")];
    for _ in 0..2 {
        let failed = u.refresh(true).unwrap();
        assert_eq!(failed.helper.status, "update_failed");
        assert!(failed.sessions.unwrap()[0].active());
    }
    assert_eq!(replacements(&f), 0);
    let (mut u, f) = setup();
    f.lock().unwrap().running = None;
    let mut failed = session("error");
    failed["errorCode"] = json!("cleanup_failed");
    f.lock().unwrap().sessions = vec![failed];
    assert_eq!(u.refresh(true).unwrap().helper.status, "update_failed");
    assert_eq!(replacements(&f), 0);
}

#[test]
fn transient_xpc_failure_reopens_without_replacing_helper() {
    let (mut u, f) = setup();
    u.refresh(true).unwrap();
    f.lock().unwrap().snapshot_error = true;
    let recovering = u.refresh(true).unwrap();
    assert_eq!(recovering.helper.status, "recovering");
    assert!(recovering.sessions.is_none());
    f.lock().unwrap().snapshot_error = false;
    assert_eq!(u.refresh(true).unwrap().helper.status, "enabled");
    assert_eq!(replacements(&f), 0);
}

#[test]
fn unresponsive_approved_helper_recovers_once_without_restart_storm() {
    let (mut u, f) = setup();
    let now = Instant::now();
    u.refresh_at(true, now).unwrap();
    f.lock().unwrap().snapshot_error = true;
    for seconds in [0, 2, 4] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "recovering"
        );
    }
    assert_eq!(replacements(&f), 0);
    assert_eq!(
        u.refresh_at(true, now + Duration::from_secs(6))
            .unwrap()
            .helper
            .status,
        "updating"
    );
    assert_eq!(replacements(&f), 1);
    f.lock().unwrap().status = "registration_pending".into();
    u.refresh_at(true, now + Duration::from_secs(7)).unwrap();
    f.lock().unwrap().snapshot_error = false;
    assert_eq!(
        u.refresh_at(true, now + Duration::from_secs(8))
            .unwrap()
            .helper
            .status,
        "enabled"
    );
    f.lock().unwrap().snapshot_error = true;
    for seconds in [10, 12, 16, 30, 60] {
        u.refresh_at(true, now + Duration::from_secs(seconds))
            .unwrap();
    }
    assert_eq!(
        u.refresh_at(true, now + Duration::from_secs(62))
            .unwrap()
            .helper
            .status,
        "update_failed"
    );
    assert_eq!(replacements(&f), 1);
}

#[test]
fn repair_can_restart_registered_unavailable_helper_but_not_disabled_helper() {
    let (mut u, f) = setup();
    f.lock().unwrap().snapshot_error = true;
    assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
    u.retry().unwrap();
    assert_eq!(u.refresh(true).unwrap().helper.status, "updating");
    assert_eq!(replacements(&f), 1);
    let (mut u, f) = setup();
    u.refresh(true).unwrap();
    f.lock().unwrap().status = "requires_approval".into();
    f.lock().unwrap().snapshot_error = true;
    assert_eq!(u.refresh(true).unwrap().helper.status, "requires_approval");
    assert_eq!(replacements(&f), 0);
    assert_eq!(registrations(&f), 0);
}

#[test]
fn recovery_never_replaces_during_quit_or_from_invalid_bundle() {
    let (mut u, f) = setup();
    let now = Instant::now();
    u.refresh(true).unwrap();
    f.lock().unwrap().snapshot_error = true;
    for seconds in [0, 2, 8, 30] {
        u.refresh_at(false, now + Duration::from_secs(seconds))
            .unwrap();
    }
    assert_eq!(replacements(&f), 0);
    let (mut u, f) = setup();
    f.lock().unwrap().snapshot_error = true;
    f.lock().unwrap().identity_error = true;
    u.retry().unwrap();
    assert_eq!(u.refresh(true).unwrap().helper.status, "update_failed");
    assert_eq!(replacements(&f), 0);
}

#[test]
fn first_launch_after_replacement_recovers_without_manual_retry() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().snapshot_error = true;
    for seconds in [0, 2, 6] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "updating"
        );
    }
    assert_eq!(replacements(&f), 1);
    f.lock().unwrap().status = "registration_pending".into();
    assert_eq!(
        u.refresh_at(true, now + Duration::from_secs(7))
            .unwrap()
            .helper
            .status,
        "updating"
    );
    f.lock().unwrap().snapshot_error = false;
    let ready = u.refresh_at(true, now + Duration::from_secs(8)).unwrap();
    assert_eq!(ready.helper.status, "enabled");
    assert!(ready.updated);
    assert_eq!(registrations(&f), 1);
    assert_eq!(replacements(&f), 1);
    assert!(!f
        .lock()
        .unwrap()
        .calls
        .iter()
        .any(|c| c == "service:reset_update" || c == "service:register"));
    for seconds in [10, 20, 60] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "enabled"
        );
    }
    assert_eq!(replacements(&f), 1);
}

#[test]
fn startup_connection_delay_does_not_restart_a_matching_helper() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().snapshot_error = true;
    assert_eq!(u.refresh_at(true, now).unwrap().helper.status, "updating");
    f.lock().unwrap().snapshot_error = false;
    assert_eq!(
        u.refresh_at(true, now + Duration::from_secs(2))
            .unwrap()
            .helper
            .status,
        "enabled"
    );
    assert_eq!(replacements(&f), 0);
}

#[test]
fn old_process_reply_after_registration_waits_and_reopens_channel_once() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().running = Some("older".into());
    u.refresh_at(true, now).unwrap();
    f.lock().unwrap().status = "enabled".into();
    for seconds in [1, 2, 10, 20] {
        let pending = u
            .refresh_at(true, now + Duration::from_secs(seconds))
            .unwrap();
        assert_eq!(pending.helper.status, "updating");
        assert!(!pending.updated);
    }
    assert_eq!(
        f.lock()
            .unwrap()
            .calls
            .iter()
            .filter(|c| *c == "service:reconnect")
            .count(),
        1
    );
    assert_eq!(replacements(&f), 1);
    f.lock().unwrap().running = Some("current".into());
    let ready = u.refresh_at(true, now + Duration::from_secs(21)).unwrap();
    assert_eq!(ready.helper.status, "enabled");
    assert!(ready.updated);
    assert_eq!(replacements(&f), 1);
}

#[test]
fn late_verified_startup_clears_failure_without_a_manual_retry() {
    for status in ["enabled", "update_failed"] {
        let (mut u, f) = setup();
        let now = Instant::now();
        f.lock().unwrap().running = None;
        u.refresh_at(true, now).unwrap();
        f.lock().unwrap().status = "enabled".into();
        f.lock().unwrap().snapshot_error = true;
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(1))
                .unwrap()
                .helper
                .status,
            "updating"
        );
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(46))
                .unwrap()
                .helper
                .status,
            "update_failed"
        );
        f.lock().unwrap().status = status.into();
        f.lock().unwrap().snapshot_error = false;
        f.lock().unwrap().running = Some("current".into());
        let ready = u.refresh_at(true, now + Duration::from_secs(47)).unwrap();
        assert_eq!(ready.helper.status, "enabled");
        assert!(ready.updated);
        assert_eq!(replacements(&f), 1);
        assert_eq!(registrations(&f), 0);
        assert!(
            !u.refresh_at(true, now + Duration::from_secs(48))
                .unwrap()
                .updated
        );
    }
}

#[test]
fn delayed_registration_can_finish_after_the_last_bounded_register_call() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().status = "not_found".into();
    f.lock().unwrap().registration_status = "registration_pending".into();
    for seconds in [0, 2, 4, 6, 12] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "updating"
        );
    }
    assert_eq!(registrations(&f), 3);
    f.lock().unwrap().status = "enabled".into(); // macOS completes in the background.
    let ready = u.refresh_at(true, now + Duration::from_secs(13)).unwrap();
    assert_eq!(ready.helper.status, "enabled");
    assert!(ready.updated);
    assert_eq!(registrations(&f), 3);
}

#[test]
fn unregister_registration_and_verification_have_separate_wait_windows() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().running = None;
    u.refresh_at(true, now).unwrap();
    f.lock().unwrap().status = "registration_pending".into();
    f.lock().unwrap().registration_status = "registration_pending".into();
    for seconds in [40, 42, 44, 60] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "updating"
        );
    }
    f.lock().unwrap().status = "enabled".into();
    f.lock().unwrap().snapshot_error = true;
    for seconds in [70, 90] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "updating"
        );
    }
    f.lock().unwrap().running = Some("current".into());
    f.lock().unwrap().snapshot_error = false;
    assert!(
        u.refresh_at(true, now + Duration::from_secs(100))
            .unwrap()
            .updated
    );
    assert_eq!(replacements(&f), 1);
    assert_eq!(registrations(&f), 3);
}

#[test]
fn temporary_unregister_failures_retry_with_a_delay_and_a_fixed_limit() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().running = None;
    u.refresh_at(true, now).unwrap();
    for seconds in [1, 4] {
        f.lock().unwrap().status = "update_retry_pending".into();
        let before = replacements(&f);
        for offset in [0, 1] {
            assert_eq!(
                u.refresh_at(true, now + Duration::from_secs(seconds + offset))
                    .unwrap()
                    .helper
                    .status,
                "updating"
            );
            assert_eq!(replacements(&f), before);
        }
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds + 2))
                .unwrap()
                .helper
                .status,
            "updating"
        );
        assert_eq!(replacements(&f), before + 1);
    }
    f.lock().unwrap().status = "update_retry_pending".into();
    for seconds in [7, 30, 90] {
        assert_eq!(
            u.refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status,
            "update_failed"
        );
    }
    assert_eq!(replacements(&f), 3);
}

#[test]
fn startup_recovery_does_not_install_from_dev_invalid_or_disabled_state() {
    for bundled in [None, Some("current".into())] {
        let (mut u, f) = setup();
        let now = Instant::now();
        f.lock().unwrap().bundled = bundled.clone();
        f.lock().unwrap().identity_error = bundled.is_some();
        f.lock().unwrap().snapshot_error = true;
        for seconds in [0, 3, 10, 60] {
            let status = u
                .refresh_at(true, now + Duration::from_secs(seconds))
                .unwrap()
                .helper
                .status;
            assert_eq!(
                status,
                if bundled.is_some() {
                    "update_failed"
                } else {
                    "unavailable"
                }
            );
        }
        assert_eq!(replacements(&f), 0);
        assert_eq!(registrations(&f), 0);
    }
}

#[test]
fn late_unregister_completion_finishes_registration_without_restarting_again() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().running = None;
    u.refresh_at(true, now).unwrap();
    assert_eq!(
        u.refresh_at(true, now + Duration::from_secs(46))
            .unwrap()
            .helper
            .status,
        "update_failed"
    );
    f.lock().unwrap().status = "registration_pending".into();
    // A Quit/status-only refresh must not install anything.
    u.refresh_at(false, now + Duration::from_secs(47)).unwrap();
    assert_eq!(registrations(&f), 0);
    assert_eq!(
        u.refresh_at(true, now + Duration::from_secs(48))
            .unwrap()
            .helper
            .status,
        "updating"
    );
    assert_eq!(registrations(&f), 1);
    f.lock().unwrap().running = Some("current".into());
    assert!(
        u.refresh_at(true, now + Duration::from_secs(49))
            .unwrap()
            .updated
    );
    assert_eq!(replacements(&f), 1);
}

#[test]
fn temporary_unregister_error_can_recover_without_user_intervention() {
    let (mut u, f) = setup();
    let now = Instant::now();
    f.lock().unwrap().running = None;
    u.refresh_at(true, now).unwrap();
    f.lock().unwrap().status = "update_retry_pending".into();
    u.refresh_at(true, now + Duration::from_secs(1)).unwrap();
    u.refresh_at(true, now + Duration::from_secs(3)).unwrap();
    f.lock().unwrap().status = "registration_pending".into();
    u.refresh_at(true, now + Duration::from_secs(4)).unwrap();
    f.lock().unwrap().running = Some("current".into());
    let ready = u.refresh_at(true, now + Duration::from_secs(5)).unwrap();
    assert_eq!(ready.helper.status, "enabled");
    assert!(ready.updated);
    assert_eq!(replacements(&f), 2);
    assert_eq!(registrations(&f), 1);
}
